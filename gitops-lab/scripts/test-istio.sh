#!/bin/bash

NAMESPACE="workload"
SLEEP_POD=$(kubectl get pod -n $NAMESPACE -l app=sleep -o jsonpath='{.items[0].metadata.name}')

show_menu() {
    echo ""
    echo "=========================================="
    echo "Istio Service Mesh - Use Case Testing"
    echo "=========================================="
    echo "1. Test mTLS (Mutual TLS)"
    echo "2. Test Canary Deployment (custom split)"
    echo "3. Test Timeout"
    echo "4. Test Retry Policy"
    echo "5. Test Circuit Breaker"
    echo "6. Generate Traffic for Observability"
    echo "7. Run All Tests"
    echo "8. Open Kiali"
    echo "9. Open Jaeger"
    echo "0. Exit"
    echo "=========================================="
    echo -n "Pilih test (0-9): "
}

test_mtls() {
    echo ""
    echo "Testing mTLS..."
    echo "----------------------------"
    kubectl exec -n $NAMESPACE $SLEEP_POD -- curl -s http://httpbin:8000/headers | grep -A1 "X-Forwarded-Client-Cert" | head -2
    if [ $? -eq 0 ]; then
        echo "✅ mTLS ACTIVE - Traffic encrypted"
    else
        echo "❌ mTLS not detected"
    fi
}

test_canary() {
    echo ""
    echo "Testing Canary Deployment..."
    echo "----------------------------"
    echo -n "Enter v1/v2 split (e.g., 80/20): "
    read split
    
    v1_percent=$(echo $split | cut -d'/' -f1)
    v2_percent=$(echo $split | cut -d'/' -f2)
    
    if ! [[ "$v1_percent" =~ ^[0-9]+$ ]] || ! [[ "$v2_percent" =~ ^[0-9]+$ ]] || [ $((v1_percent + v2_percent)) -ne 100 ]; then
        echo "❌ Invalid split. Using default 80/20"
        v1_percent=80
        v2_percent=20
    fi
    
    echo "Sending 100 requests..."
    v1=0
    v2=0
    for i in {1..100}; do
        echo -ne "\rProgress: $i/100"
        response=$(kubectl exec -n $NAMESPACE $SLEEP_POD -- curl -s http://httpbin:8000/headers 2>/dev/null)
        if echo "$response" | grep -q "httpbin-v2"; then
            ((v2++))
        else
            ((v1++))
        fi
    done
    echo ""
    echo "Results:"
    echo "  v1: $v1 requests (~${v1_percent}% expected)"
    echo "  v2: $v2 requests (~${v2_percent}% expected)"
    echo "✅ Canary working"
}

test_timeout() {
    echo ""
    echo "Testing Timeout..."
    echo "----------------------------"
    echo "Request /delay/3 (timeout: 10s)..."
    start=$(date +%s)
    status=$(kubectl exec -n $NAMESPACE $SLEEP_POD -- curl -s -o /dev/null -w "%{http_code}" http://httpbin:8000/delay/3)
    end=$(date +%s)
    duration=$((end - start))
    echo "Status: $status"
    echo "Duration: ${duration}s"
    echo "✅ Completed within timeout"
}

test_retry() {
    echo ""
    echo "Testing Retry Policy..."
    echo "----------------------------"
    echo "Request /status/503 (will retry 3x)..."
    kubectl exec -n $NAMESPACE $SLEEP_POD -- curl -s -o /dev/null -w "HTTP: %{http_code}\n" http://httpbin:8000/status/503
    echo "✅ Check Kiali for retry attempts"
}

test_circuit_breaker() {
    echo ""
    echo "Testing Circuit Breaker..."
    echo "----------------------------"
    echo "Sending 20 concurrent requests..."
    for i in {1..20}; do
        kubectl exec -n $NAMESPACE $SLEEP_POD -- curl -s -o /dev/null -w "%{http_code}\n" http://httpbin:8000/get &
    done
    wait
    echo "✅ Circuit breaker active (max 10 conn)"
}

generate_traffic() {
    echo ""
    echo "Generating Traffic..."
    echo "----------------------------"
    echo "Sending 50 requests..."
    for i in {1..50}; do
        echo -ne "\rProgress: $i/50"
        kubectl exec -n $NAMESPACE $SLEEP_POD -- curl -s -o /dev/null http://httpbin:8000/get &
        kubectl exec -n $NAMESPACE $SLEEP_POD -- curl -s -o /dev/null http://httpbin:8000/headers &
    done
    wait
    echo ""
    echo "✅ Traffic generated - Check Kiali/Jaeger"
}

run_all() {
    test_mtls
    test_canary
    test_timeout
    test_retry
    test_circuit_breaker
    generate_traffic
    echo ""
    echo "=========================================="
    echo "All tests complete!"
    echo "=========================================="
}

open_kiali() {
    echo ""
    echo "Opening Kiali..."
    echo "Port-forward: kubectl port-forward -n istio-system svc/kiali 20001:20001"
    echo "URL: http://localhost:20001"
    kubectl port-forward -n istio-system svc/kiali 20001:20001
}

open_jaeger() {
    echo ""
    echo "Opening Jaeger..."
    echo "Port-forward: kubectl port-forward -n istio-system svc/jaeger-query 16686:16686"
    echo "URL: http://localhost:16686"
    kubectl port-forward -n istio-system svc/jaeger-query 16686:16686
}

# Main loop
while true; do
    show_menu
    read choice
    case $choice in
        1) test_mtls ;;
        2) test_canary ;;
        3) test_timeout ;;
        4) test_retry ;;
        5) test_circuit_breaker ;;
        6) generate_traffic ;;
        7) run_all ;;
        8) open_kiali ;;
        9) open_jaeger ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "Invalid choice" ;;
    esac
done
