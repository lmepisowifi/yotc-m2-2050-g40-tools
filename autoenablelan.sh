cat > /config/port_watchdog.sh << 'EOF'
#!/bin/sh

PORTS="0 1"
PIDFILE="/tmp/port_watchdog.pid"
LOG="/tmp/port_watchdog.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

MYPID=$$
for PID in $(cat "$PIDFILE" 2>/dev/null); do
    if [ "$PID" != "$MYPID" ] && kill -0 "$PID" 2>/dev/null; then
        log "Killing duplicate watchdog PID $PID"
        kill "$PID" 2>/dev/null
    fi
done
echo "$MYPID" > "$PIDFILE"

# Detach from controlling tty completely so diag/mib output can't stop us
exec >> "$LOG" 2>&1
exec < /dev/null

log "=== Watchdog started (PID $MYPID) ==="

check_and_restore_port() {
    PORT="$1"
    ENABLE=$(mib get SW_PORT_TBL.${PORT} 2>/dev/null | awk -F'=' '/^[[:space:]]*Enable/{gsub(/ /,"",$2); print $2}')
    if [ -z "$ENABLE" ]; then
        log "WARNING: Could not read SW_PORT_TBL.${PORT} - skipping"
        return
    fi
    if [ "$ENABLE" = "0" ]; then
        log "Port ${PORT}: Enable=0 detected, restoring..."
        mib set SW_PORT_TBL.${PORT}.Enable 1 && log "Port ${PORT}: mib set Enable=1 OK" || log "Port ${PORT}: mib set Enable=1 FAILED"
        mib commit && log "Port ${PORT}: mib commit OK" || log "Port ${PORT}: mib commit FAILED"
    else
        log "Port ${PORT}: Enable=${ENABLE}, OK"
    fi

    PWRDOWN=$(diag port get phy-force-power-down port ${PORT} 2>/dev/null | awk '/^port:'${PORT}'/{print $2}')
    if [ "$PWRDOWN" = "Enable" ]; then
        log "Port ${PORT}: phy-force-power-down is Enable, disabling..."
        diag port set phy-force-power-down port ${PORT} state disable && log "Port ${PORT}: phy-force-power-down disabled OK" || log "Port ${PORT}: phy-force-power-down disable FAILED"
    else
        log "Port ${PORT}: phy-force-power-down=${PWRDOWN}, OK"
    fi
}

while true; do
    for PORT in $PORTS; do
        check_and_restore_port "$PORT"
    done
    sleep 30
done
EOF

chmod +x /config/port_watchdog.sh

grep -q "port_watchdog.sh" /config/run_test.sh 2>/dev/null || echo "(/config/port_watchdog.sh >> /tmp/port_watchdog.log 2>&1) &" >> /config/run_test.sh

for PID in $(ps 2>/dev/null | grep "port_watchdog" | grep -v grep | awk '{print $1}'); do kill "$PID" 2>/dev/null; done; sleep 1

rm -f /tmp/port_watchdog.log /tmp/port_watchdog.pid

(/config/port_watchdog.sh >> /tmp/port_watchdog.log 2>&1) &

chmod +x /config/run_test.sh

echo "activated watchdog, will automatically re-enable the lan ports, you can close the app now (pid: $!)"
