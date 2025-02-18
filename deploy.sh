#!/bin/bash
set -e

WORKDIR=$(pwd)
LOG_FILE=$WORKDIR/deployment.log

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a $LOG_FILE
}

verify_health() {
    local port=$1
    local retries=30
    local wait_time=2
    
    log "Verifying health of environment on port $port"
    
    for i in $(seq 1 $retries); do
        if curl -s http://localhost:$port/health | grep -q "healthy"; then
            log "Health check passed after $i attempts"
            return 0
        fi
        log "Health check attempt $i/$retries failed, waiting ${wait_time}s..."
        sleep $wait_time
    done
    
    log "ERROR: Health check failed after $retries attempts"
    return 1
}

# Initialize active environment if not set
if [ ! -f $WORKDIR/.active_env ]; then
    log "Initializing active environment as blue"
    echo "blue" > $WORKDIR/.active_env
fi

# Get current active environment
CURRENT_ENV=$(cat $WORKDIR/.active_env)
log "Current active environment: $CURRENT_ENV"

# Determine target environment
if [ "$CURRENT_ENV" = "blue" ]; then
    TARGET_ENV="green"
    TARGET_PORT="8082"
    CURRENT_PORT="8081"
else
    TARGET_ENV="blue"
    TARGET_PORT="8081"
    CURRENT_PORT="8082"
fi

log "Starting deployment to $TARGET_ENV environment"

# Start target environment
cd $WORKDIR/$TARGET_ENV
log "Building and starting $TARGET_ENV environment"
docker-compose up -d --build

# Verify health of new environment
if ! verify_health $TARGET_PORT; then
    log "ERROR: New environment failed health checks. Rolling back..."
    docker-compose down
    exit 1
fi

# Update proxy configuration
log "Updating proxy configuration to point to $TARGET_ENV environment"
sed -i "s/server localhost:$CURRENT_PORT;/server localhost:$TARGET_PORT;/" $WORKDIR/proxy/nginx.conf

# Reload proxy
log "Reloading proxy configuration"
if docker exec proxy nginx -s reload; then
    log "Proxy reload successful"
    echo $TARGET_ENV > $WORKDIR/.active_env
    log "Successfully switched to $TARGET_ENV environment"
    
    # Verify the switch
    if verify_health 80; then
        log "Proxy health check passed. Deployment successful!"
    else
        log "WARNING: Proxy health check failed after switch. Please investigate."
    fi
else
    log "ERROR: Failed to reload proxy. Rolling back configuration..."
    sed -i "s/server localhost:$TARGET_PORT;/server localhost:$CURRENT_PORT;/" $WORKDIR/proxy/nginx.conf
    docker exec proxy nginx -s reload
    docker-compose down
    exit 1
fi

# Keep old environment running for potential rollback
log "Deployment completed. Old environment ($CURRENT_ENV) kept running for safety"
log "To remove old environment, run: cd $WORKDIR/$CURRENT_ENV && docker-compose down"
