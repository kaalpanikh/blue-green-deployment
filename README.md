# Blue-Green Deployment Project

This project implements a blue-green deployment strategy for a production-ready Todo API application that is currently running on AWS EC2. The goal is to achieve zero-downtime deployments by running two identical production environments.

## Current Infrastructure

### Production Environment
- **Server**: 44.203.38.191 (Ubuntu) - Control Node
- **Domain**: mca.nikhilmishra.live
- **Application Stack**:
  - Node.js Todo API (Express.js)
  - MongoDB Database
  - Nginx Reverse Proxy
  - Docker and Docker Compose
  - GitHub Actions CI/CD

### Current Architecture
```
                                              AWS EC2 Control Node (44.203.38.191)
                                              ┌─────────────────────────────────┐
Client -> mca.nikhilmishra.live -> Nginx -> │ Node.js API -> MongoDB          │
                                              └─────────────────────────────────┘
```

### Target Blue-Green Architecture
```
                                              AWS EC2 Control Node (44.203.38.191)
                                              ┌─────────────────────────────────┐
                                              │ Blue Environment                │
                                              │   ├─ Node.js API (Port 3000)   │
Client -> mca.nikhilmishra.live -> Nginx -> │   └─ MongoDB (Port 27017)      │
                                              │                                 │
                                              │ Green Environment              │
                                              │   ├─ Node.js API (Port 3001)   │
                                              │   └─ MongoDB (Port 27018)      │
                                              └─────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Infrastructure Preparation
1. Back up current production environment:
   ```bash
   # On Control Node (44.203.38.191)
   # Backup MongoDB
   docker exec mongodb mongodump --out /data/backup/$(date +%Y%m%d)
   
   # Backup current configurations
   sudo cp /etc/nginx/conf.d/app.conf /etc/nginx/conf.d/app.conf.backup
   cp docker-compose.yml docker-compose.yml.backup
   ```

2. Create directory structure:
   ```bash
   # On Control Node
   sudo mkdir -p /opt/{blue,green}/app
   sudo mkdir -p /opt/scripts
   ```

### Phase 2: Blue Environment Setup (Current Production)
1. Move current application to blue environment:
   ```bash
   # On Control Node
   sudo mv /opt/app/* /opt/blue/app/
   sudo ln -s /opt/blue /opt/current
   ```

2. Update blue environment Docker Compose:
   ```yaml
   # /opt/blue/docker-compose.yml
   version: '3.8'
   services:
     api:
       container_name: blue-api
       build: ./app
       ports:
         - "3000:3000"
       environment:
         - MONGODB_URI=mongodb://blue-mongodb:27017/todos
       depends_on:
         - mongodb
     
     mongodb:
       container_name: blue-mongodb
       image: mongo:latest
       ports:
         - "27017:27017"
       volumes:
         - blue-mongodb-data:/data/db

   volumes:
     blue-mongodb-data:
   ```

### Phase 3: Green Environment Setup
1. Create green environment:
   ```bash
   # On Control Node
   sudo cp -r /opt/blue/app/* /opt/green/app/
   ```

2. Create green environment Docker Compose:
   ```yaml
   # /opt/green/docker-compose.yml
   version: '3.8'
   services:
     api:
       container_name: green-api
       build: ./app
       ports:
         - "3001:3000"
       environment:
         - MONGODB_URI=mongodb://green-mongodb:27017/todos
       depends_on:
         - mongodb
     
     mongodb:
       container_name: green-mongodb
       image: mongo:latest
       ports:
         - "27018:27017"
       volumes:
         - green-mongodb-data:/data/db

   volumes:
     green-mongodb-data:
   ```

### Phase 4: Load Balancer Configuration
1. Update Nginx configuration:
   ```nginx
   # /etc/nginx/conf.d/app.conf
   upstream blue {
       server localhost:3000;
   }

   upstream green {
       server localhost:3001;
   }

   # Production traffic points to active environment
   upstream production {
       server localhost:3000;  # Initially points to blue
   }

   server {
       listen 80;
       server_name mca.nikhilmishra.live;

       location / {
           proxy_pass http://production;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection 'upgrade';
           proxy_set_header Host $host;
           proxy_cache_bypass $http_upgrade;
       }

       # Health check endpoint
       location /health {
           proxy_pass http://production/health;
       }
   }
   ```

### Phase 5: Deployment Scripts
1. Create deployment scripts:
   ```bash
   # /opt/scripts/deploy.sh
   #!/bin/bash
   
   # Determine target environment
   CURRENT=$(readlink /opt/current)
   if [ "$CURRENT" = "blue" ]; then
     TARGET_ENV="green"
     TARGET_PORT="3001"
   else
     TARGET_ENV="blue"
     TARGET_PORT="3000"
   fi
   
   echo "Deploying to $TARGET_ENV environment..."
   
   # Deploy to target environment
   cd /opt/$TARGET_ENV
   docker-compose pull
   docker-compose up -d
   
   # Wait for health check
   for i in {1..30}; do
     if curl -s http://localhost:$TARGET_PORT/health | grep -q "ok"; then
       echo "Health check passed"
       # Switch traffic
       sudo /opt/scripts/switch-traffic.sh $TARGET_ENV
       exit 0
     fi
     sleep 2
   done
   
   echo "Health check failed"
   /opt/scripts/rollback.sh
   exit 1
   ```

   ```bash
   # /opt/scripts/switch-traffic.sh
   #!/bin/bash
   TARGET_ENV=$1
   TARGET_PORT=$([ "$TARGET_ENV" = "blue" ] && echo "3000" || echo "3001")
   
   # Update Nginx upstream
   sed -i "s/server localhost:[0-9]\+/server localhost:$TARGET_PORT/" /etc/nginx/conf.d/app.conf
   nginx -s reload
   
   # Update current symlink
   ln -sf /opt/$TARGET_ENV /opt/current
   ```

   ```bash
   # /opt/scripts/rollback.sh
   #!/bin/bash
   CURRENT=$(readlink /opt/current)
   
   if [ "$CURRENT" = "blue" ]; then
     /opt/scripts/switch-traffic.sh green
   else
     /opt/scripts/switch-traffic.sh blue
   fi
   ```

2. Make scripts executable:
   ```bash
   chmod +x /opt/scripts/*.sh
   ```

### Phase 6: Database Management
1. Create database sync script:
   ```bash
   # /opt/scripts/sync-db.sh
   #!/bin/bash
   
   CURRENT=$(readlink /opt/current)
   if [ "$CURRENT" = "blue" ]; then
     SRC_CONTAINER="blue-mongodb"
     DST_CONTAINER="green-mongodb"
   else
     SRC_CONTAINER="green-mongodb"
     DST_CONTAINER="blue-mongodb"
   fi
   
   # Dump from source
   docker exec $SRC_CONTAINER mongodump --out /tmp/db_backup
   
   # Restore to destination
   docker cp $SRC_CONTAINER:/tmp/db_backup /tmp/
   docker cp /tmp/db_backup $DST_CONTAINER:/tmp/
   docker exec $DST_CONTAINER mongorestore --drop /tmp/db_backup
   ```

### Phase 7: GitHub Actions Workflow
1. Update workflow file:
   ```yaml
   # .github/workflows/deploy.yml
   name: Deploy

   on:
     push:
       branches: [ main ]

   jobs:
     deploy:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v2
         
         - name: Deploy to EC2
           uses: appleboy/ssh-action@master
           with:
             host: 44.203.38.191
             username: ubuntu
             key: ${{ secrets.SSH_PRIVATE_KEY }}
             script: |
               cd /opt/scripts
               ./deploy.sh

         - name: Notify on failure
           if: failure()
           run: |
             echo "Deployment failed, check logs"
   ```

## Project Structure on Control Node

```
/opt/
├── current -> blue/          # Symlink to current environment
├── blue/                     # Blue environment
│   ├── app/
│   │   ├── src/
│   │   └── package.json
│   └── docker-compose.yml
├── green/                    # Green environment
│   ├── app/
│   │   ├── src/
│   │   └── package.json
│   └── docker-compose.yml
├── scripts/
│   ├── deploy.sh
│   ├── switch-traffic.sh
│   ├── rollback.sh
│   └── sync-db.sh
└── backup/                   # Database backups
```

## Getting Started

1. SSH into the control node:
   ```bash
   ssh ubuntu@44.203.38.191
   ```

2. Set up initial structure:
   ```bash
   # Create directories
   sudo mkdir -p /opt/{blue,green}/app /opt/scripts /opt/backup
   
   # Move current app to blue environment
   sudo mv /opt/app/* /opt/blue/app/
   sudo ln -s /opt/blue /opt/current
   
   # Copy deployment scripts
   sudo cp -r scripts/* /opt/scripts/
   sudo chmod +x /opt/scripts/*.sh
   ```

3. Test deployment:
   ```bash
   cd /opt/scripts
   ./deploy.sh
   ```

## Contributing

This project is part of the learning journey from [roadmap.sh](https://roadmap.sh/projects/blue-green-deployment).

## License

MIT License