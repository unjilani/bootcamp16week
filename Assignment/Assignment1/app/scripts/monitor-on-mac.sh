#!/bin/bash
#
# Container Monitoring Script - Fixed for local execution
# Monitors Docker container resources and application health
#

# Configuration
CONTAINER_NAME="${CONTAINER_NAME:-monitored-app}"
LOG_FILE="/var/log/container_monitor.log"
ALERT_LOG="/var/log/container_alerts.log"
METRICS_FILE="/var/log/container_metrics.csv"

# Thresholds
CPU_THRESHOLD="${CPU_THRESHOLD:-40}"
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-80}"
RESPONSE_TIME_THRESHOLD="${RESPONSE_TIME_THRESHOLD:-1000}"

# Initialize log files
initialize_logs() {
    touch "$LOG_FILE" "$ALERT_LOG" "$METRICS_FILE"
    if [ ! -s "$METRICS_FILE" ]; then
        echo "timestamp,cpu_percent,memory_usage_mb,memory_percent,response_time_ms,status" > "$METRICS_FILE"
    fi
}

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Alert function
send_alert() {
    local alert_type="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ALERT: $alert_type - $message" | tee -a "$ALERT_LOG"
}

# Check if container is running
check_container_status() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Get container statistics
get_container_stats() {
    local stats=$(docker stats --no-stream --format "{{json .}}" "$CONTAINER_NAME" 2>/dev/null)
    
    if [ -z "$stats" ]; then
        echo "0,0,0"
        return
    fi
    
    # Parse CPU percentage (remove % sign)
    local cpu=$(echo "$stats" | grep -o '"CPUPerc":"[^"]*"' | cut -d'"' -f4 | tr -d '%')
    
    # Parse memory usage
    local mem_usage=$(echo "$stats" | grep -o '"MemUsage":"[^"]*"' | cut -d'"' -f4 | cut -d'/' -f1)
    local mem_limit=$(echo "$stats" | grep -o '"MemUsage":"[^"]*"' | cut -d'"' -f4 | cut -d'/' -f2)
    
    # Convert memory to MB (handle both MiB and GiB)
    local mem_usage_mb=$(echo "$mem_usage" | sed 's/MiB//' | sed 's/GiB/*1024/')
    local mem_limit_mb=$(echo "$mem_limit" | sed 's/MiB//' | sed 's/GiB/*1024/')
    
    # Use bc only if available, otherwise use awk
    if command -v bc >/dev/null 2>&1; then
        mem_usage_mb=$(echo "$mem_usage_mb" | bc 2>/dev/null || echo "0")
        mem_limit_mb=$(echo "$mem_limit_mb" | bc 2>/dev/null || echo "256")
    else
        mem_usage_mb=$(awk "BEGIN {print $mem_usage_mb}")
        mem_limit_mb=$(awk "BEGIN {print $mem_limit_mb}")
    fi
    
    # Calculate memory percentage using awk
    local mem_percent=0
    if [ "$mem_limit_mb" != "0" ] && [ "$mem_limit_mb" != "" ]; then
        mem_percent=$(awk "BEGIN {printf \"%.2f\", ($mem_usage_mb / $mem_limit_mb) * 100}")
    fi
    
    echo "$cpu,$mem_usage_mb,$mem_percent"
}

# Check application health with cross-platform time calculation
check_app_health() {
    # Determine the correct URL based on execution environment
    local health_url
    
    # Check if running inside Docker container (monitor container)
    if [ -f /.dockerenv ]; then
        # Running inside Docker - use container name
        health_url="http://${CONTAINER_NAME}:80/health"
    else
        # Running locally - use localhost with mapped port
        # Extract the host port mapping for the container
        local host_port=$(docker port "$CONTAINER_NAME" 80 2>/dev/null | cut -d: -f2)
        if [ -n "$host_port" ]; then
            health_url="http://localhost:${host_port}/health"
        else
            # Fallback to default port from docker-compose
            health_url="http://localhost:8080/health"
        fi
    fi
    
    echo "Checking health at: $health_url" >&2  # Debug output
    
    # Cross-platform millisecond time calculation
    local start_time
    local end_time
    
    # Try different methods to get milliseconds
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        start_time=$(python3 -c 'import time; print(int(time.time() * 1000))')
    elif [[ -x "$(command -v date)" ]] && date +%s%3N >/dev/null 2>&1; then
        # Linux with GNU date
        start_time=$(date +%s%3N)
    else
        # Fallback to seconds
        start_time=$(date +%s)000
    fi
    
    # Make HTTP request to health endpoint
    local response=$(curl -s -w "\n%{http_code}" "$health_url" 2>/dev/null || echo -e "\n000")
    
    # Get end time using same method
    if [[ "$OSTYPE" == "darwin"* ]]; then
        end_time=$(python3 -c 'import time; print(int(time.time() * 1000))')
    elif [[ -x "$(command -v date)" ]] && date +%s%3N >/dev/null 2>&1; then
        end_time=$(date +%s%3N)
    else
        end_time=$(date +%s)000
    fi
    
    # Extract HTTP status code (last line of response)
    local http_code=$(echo "$response" | tail -n1)
    
    # Calculate response time
    local response_time=$((end_time - start_time))
    
    # Ensure response_time is a valid number
    if [[ ! "$response_time" =~ ^[0-9]+$ ]]; then
        response_time=0
    fi
    
    # Determine health status based on HTTP code
    if [ "$http_code" = "200" ]; then
        echo "$response_time,healthy"
    else
        echo "$response_time,unhealthy"
    fi
}

# Main monitoring function
monitor_container() {
    log_message "INFO" "Starting container monitoring for $CONTAINER_NAME"
    
    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_message "ERROR" "Container $CONTAINER_NAME not found"
        return 1
    fi
    
    # Check container status
    local status=$(check_container_status)
    if [ "$status" != "running" ]; then
        send_alert "Container Down" "Container $CONTAINER_NAME is not running"
        return 1
    fi
    
    # Get container stats
    IFS=',' read -r cpu mem_usage_mb mem_percent <<< "$(get_container_stats)"
    
    # Get application health
    IFS=',' read -r response_time app_status <<< "$(check_app_health)"
    
    # Ensure values are valid numbers
    cpu=${cpu:-0}
    mem_usage_mb=${mem_usage_mb:-0}
    mem_percent=${mem_percent:-0}
    response_time=${response_time:-0}
    
    # Log metrics
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp,$cpu,$mem_usage_mb,$mem_percent,$response_time,$app_status" >> "$METRICS_FILE"
    
    log_message "INFO" "CPU: ${cpu}%, Memory: ${mem_usage_mb}MB (${mem_percent}%), Response Time: ${response_time}ms, Status: $app_status"
    
    # Check thresholds and send alerts
    # Use awk for floating point comparison
    if [ -n "$cpu" ] && [ "$cpu" != "0" ]; then
        if awk "BEGIN {exit !($cpu > $CPU_THRESHOLD)}"; then
            send_alert "High CPU" "CPU usage is ${cpu}% (threshold: ${CPU_THRESHOLD}%)"
        fi
    fi
    
    if [ -n "$mem_percent" ] && [ "$mem_percent" != "0" ]; then
        if awk "BEGIN {exit !($mem_percent > $MEMORY_THRESHOLD)}"; then
            send_alert "High Memory" "Memory usage is ${mem_percent}% (threshold: ${MEMORY_THRESHOLD}%)"
        fi
    fi
    
    if [ -n "$response_time" ] && [ "$response_time" -gt "$RESPONSE_TIME_THRESHOLD" ] 2>/dev/null; then
        send_alert "Slow Response" "Response time is ${response_time}ms (threshold: ${RESPONSE_TIME_THRESHOLD}ms)"
    fi
    
    if [ "$app_status" != "healthy" ]; then
        send_alert "Application Unhealthy" "Application health check failed"
    fi
}

# Generate monitoring report
generate_report() {
    local report_file="/var/log/container_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "Container Monitoring Report"
        echo "=========================="
        echo "Generated: $(date)"
        echo "Container: $CONTAINER_NAME"
        echo ""
        echo "Summary Statistics:"
        echo "-------------------"
        
        if [ -f "$METRICS_FILE" ]; then
            # Calculate averages
            local avg_cpu=$(awk -F',' 'NR>1 {sum+=$2; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}' "$METRICS_FILE")
            local avg_mem=$(awk -F',' 'NR>1 {sum+=$4; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}' "$METRICS_FILE")
            local avg_response=$(awk -F',' 'NR>1 {sum+=$5; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}' "$METRICS_FILE")
            
            echo "Average CPU Usage: ${avg_cpu}%"
            echo "Average Memory Usage: ${avg_mem}%"
            echo "Average Response Time: ${avg_response}ms"
            echo ""
            echo "Recent Alerts:"
            echo "--------------"
            tail -10 "$ALERT_LOG" 2>/dev/null || echo "No recent alerts"
        fi
    } > "$report_file"
    
    log_message "INFO" "Report generated: $report_file"
    echo "$report_file"
}

# Function to draw a progress bar
draw_bar() {
    local value=$1
    local width=$2
    
    # Ensure value is a valid number
    if [[ ! "$value" =~ ^[0-9.]+$ ]]; then
        value=0
    fi
    
    # Calculate filled portion using awk
    local filled=$(awk "BEGIN {printf \"%.0f\", $value * $width / 100}")
    local empty=$((width - filled))
    
    # Color codes based on value
    local color="\e[32m"  # Green
    if awk "BEGIN {exit !($value > 80)}"; then
        color="\e[31m"    # Red
    elif awk "BEGIN {exit !($value > 60)}"; then
        color="\e[33m"    # Yellow
    fi
    
    echo -en "${color}"
    printf '▓%.0s' $(seq 1 $filled 2>/dev/null || jot $filled)
    echo -en "\e[0m"
    printf '░%.0s' $(seq 1 $empty 2>/dev/null || jot $empty)
    echo ""
}

# Live monitoring with visual display
live_monitor() {
    initialize_logs
    log_message "INFO" "Starting live monitoring mode"
    
    # Clear screen
    clear
    
    # Trap CTRL+C to exit cleanly
    trap 'echo -e "\n\nExiting live monitor..."; exit 0' SIGINT
    
    while true; do
        # Move cursor to top
        tput cup 0 0
        
        # Print header
        echo "╔════════════════════════════════════════════════════════════════════╗"
        echo "║              Container Live Monitor - $(date '+%Y-%m-%d %H:%M:%S')              ║"
        echo "╚════════════════════════════════════════════════════════════════════╝"
        echo ""
        
        # Check container status
        local status=$(check_container_status)
        if [ "$status" != "running" ]; then
            echo "🔴 Container Status: STOPPED"
            echo ""
            echo "Waiting for container to start..."
            sleep 2
            continue
        fi
        
        # Get container stats
        IFS=',' read -r cpu mem_usage_mb mem_percent <<< "$(get_container_stats)"
        
        # Get application health
        IFS=',' read -r response_time app_status <<< "$(check_app_health)"
        
        # Ensure values are valid
        cpu=${cpu:-0}
        mem_usage_mb=${mem_usage_mb:-0}
        mem_percent=${mem_percent:-0}
        response_time=${response_time:-0}
        
        # Display status
        echo "🟢 Container Status: RUNNING"
        echo ""
        echo "📊 Resource Usage:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # CPU gauge
        echo -n "CPU Usage:     "
        printf "%5.1f%% " "$cpu"
        draw_bar "$cpu" 50
        
        # Memory gauge
        echo -n "Memory Usage:  "
        printf "%5.1f%% " "$mem_percent"
        draw_bar "$mem_percent" 50
        
        echo ""
        echo "📈 Performance Metrics:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Memory Used:     ${mem_usage_mb} MB"
        echo "Response Time:   ${response_time} ms"
        
        # Convert to uppercase using tr instead of ${^^}
        app_status_upper=$(echo "$app_status" | tr '[:lower:]' '[:upper:]')
        echo "App Health:      ${app_status_upper}"
        
        # Check thresholds and display alerts
        echo ""
        echo "⚠️  Alerts:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        local alerts=0
        
        # Use awk for numeric comparisons
        if [ -n "$cpu" ] && awk "BEGIN {exit !($cpu > $CPU_THRESHOLD)}"; then
            echo "🔴 HIGH CPU: ${cpu}% (threshold: ${CPU_THRESHOLD}%)"
            ((alerts++))
        fi
        
        if [ -n "$mem_percent" ] && awk "BEGIN {exit !($mem_percent > $MEMORY_THRESHOLD)}"; then
            echo "🔴 HIGH MEMORY: ${mem_percent}% (threshold: ${MEMORY_THRESHOLD}%)"
            ((alerts++))
        fi
        
        if [ -n "$response_time" ] && [ "$response_time" -gt "$RESPONSE_TIME_THRESHOLD" ] 2>/dev/null; then
            echo "🔴 SLOW RESPONSE: ${response_time}ms (threshold: ${RESPONSE_TIME_THRESHOLD}ms)"
            ((alerts++))
        fi
        
        if [ "$app_status" != "healthy" ]; then
            echo "🔴 APPLICATION UNHEALTHY"
            ((alerts++))
        fi
        
        if [ "$alerts" -eq 0 ]; then
            echo "✅ All systems normal"
        fi
        
        # Display recent log entries
        echo ""
        echo "📋 Recent Activity:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        tail -3 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
        
        # Instructions
        echo ""
        echo "Press Ctrl+C to exit"
        
        # Log metrics for monitoring
        monitor_container
        
        # Sleep for refresh interval
        sleep 2
    done
}

# Main execution
main() {
    case "${1:-monitor}" in
        monitor)
            initialize_logs
            monitor_container
            ;;
        report)
            generate_report
            ;;
        continuous)
            initialize_logs
            log_message "INFO" "Starting continuous monitoring (Ctrl+C to stop)"
            while true; do
                monitor_container
                sleep 60  # Check every minute
            done
            ;;
        live)
            live_monitor
            ;;
        *)
            echo "Usage: $0 [monitor|report|continuous|live]"
            exit 1
            ;;
    esac
}

main "$@"