#!/bin/bash
# Auto-installer service

# Simple logging function
log() {
    echo "[$(date)] $*" | tee -a /tmp/auto-installer.log
}

log "AUTO-INSTALLER SCRIPT STARTED"
log "Current working directory: $(pwd)"
log "Current user: $(whoami)"
log "Current PATH: $PATH"

# Wait for system to be fully ready
log "Waiting for system to be fully ready..."
sleep 5

# Wait for essential services
log "Waiting for essential services..."
for i in {1..30}; do
    if systemctl is-active multi-user.target >/dev/null 2>&1; then
        log "System is ready (attempt $i)"
        break
    fi
    log "Waiting for system readiness... (attempt $i/30)"
    sleep 2
done

# Ensure we have a proper environment
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Check if autoinstall parameter is present
log "Checking for autoinstall=true parameter..."
if grep -q "autoinstall=true" /proc/cmdline; then
    log "AUTO-INSTALL MODE DETECTED"
    log "=========================="
    
    log "Starting installation immediately..."
    
    log "Executing automatic installation..."
    
    # Ensure we're in the right directory and have proper permissions
    cd /
    
    # Run installation with error checking
    if /usr/local/bin/install-system 2>&1 | tee -a /tmp/auto-installer.log; then
        INSTALL_EXIT_CODE=0
    else
        INSTALL_EXIT_CODE=1
    fi
    
    log "INSTALL-SYSTEM EXECUTION FINISHED"
    log "install-system completed with exit code: $INSTALL_EXIT_CODE"
    
    if [ $INSTALL_EXIT_CODE -eq 0 ]; then
        log "INSTALLATION COMPLETED SUCCESSFULLY!"
        
        # Wait a bit for installation to complete
        sleep 5
        
        log "Auto-installation completed. System will reboot."
        
        # Reboot the system
        reboot
    else
        log "INSTALLATION FAILED!"
        log "Check /tmp/auto-installer.log for details"
        log "You can run 'sudo install-system' manually to try again"
        
        # Don't reboot on failure - let user investigate
        log "System will remain running for manual investigation"
    fi
else
    log "autoinstall=true parameter NOT FOUND in kernel cmdline"
    log "Current cmdline: $(cat /proc/cmdline)"
fi

log "AUTO-INSTALLER SCRIPT FINISHED"