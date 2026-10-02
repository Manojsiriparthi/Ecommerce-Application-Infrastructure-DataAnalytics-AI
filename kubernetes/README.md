# Kubernetes Deployment for E-Commerce Application

This directory contains all Kubernetes manifests for deploying the e-commerce microservices application.

## Directory Structure

```
kubernetes/
├── namespace.yaml              # Namespace definition
├── frontend/                   # Frontend Next.js application
│   ├── deployment.yaml        # Frontend deployment
│   ├── service.yaml           # Frontend service (LoadBalancer)
│   ├── configmap.yaml         # Frontend configuration
│   └── hpa.yaml              # Horizontal Pod Autoscaler
├── services/                   # Microservices
│   ├── user-service/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── product-service/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── cart-service/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── order-service/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── payment-service/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   └── notification-service/
│       ├── deployment.yaml
│       └── service.yaml
└── db/                        # Database (StatefulSet)
    ├── namespace.yaml
    ├── postgres-statefulset.yaml
    ├── postgres-service.yaml
    ├── postgres-configmap.yaml
    ├── postgres-secret.yaml
    └── README.md
```

## Deployment Instructions

### Prerequisites
- Kubernetes cluster (v1.21+)
- kubectl configured with cluster access
- Container images built and pushed to registry

### Step 1: Create Namespace
```bash
kubectl apply -f kubernetes/namespace.yaml
```

### Step 2: Deploy Database (PostgreSQL)
```bash
kubectl apply -f kubernetes/db/postgres-secret.yaml
kubectl apply -f kubernetes/db/postgres-configmap.yaml
kubectl apply -f kubernetes/db/postgres-statefulset.yaml
kubectl apply -f kubernetes/db/postgres-service.yaml
```

Wait for PostgreSQL to be ready:
```bash
kubectl rollout status statefulset/postgres-statefulset -n ecommerce
```

### Step 3: Deploy Microservices
```bash
# Deploy each service
kubectl apply -f kubernetes/services/user-service/
kubectl apply -f kubernetes/services/product-service/
kubectl apply -f kubernetes/services/cart-service/
kubectl apply -f kubernetes/services/order-service/
kubectl apply -f kubernetes/services/payment-service/
kubectl apply -f kubernetes/services/notification-service/
```

### Step 4: Deploy Frontend
```bash
kubectl apply -f kubernetes/frontend/
```

Wait for Frontend to be ready:
```bash
kubectl rollout status deployment/frontend-deployment -n ecommerce
```

## Verification

### Check all resources
```bash
kubectl get all -n ecommerce
```

### Check specific deployments
```bash
kubectl get deployments -n ecommerce
kubectl get statefulsets -n ecommerce
kubectl get services -n ecommerce
```

### View logs
```bash
# Frontend logs
kubectl logs -n ecommerce deployment/frontend-deployment -f

# User service logs
kubectl logs -n ecommerce deployment/user-service-deployment -f

# Database logs
kubectl logs -n ecommerce statefulset/postgres-statefulset -f
```

### Port Forward to Access Services
```bash
# Access Frontend
kubectl port-forward -n ecommerce svc/frontend-service 3000:80

# Access PostgreSQL (for debugging)
kubectl port-forward -n ecommerce svc/postgres-service 5432:5432
```

## Configuration

### Database Credentials
Update `kubernetes/db/postgres-secret.yaml` with secure credentials before deploying to production.

### Environment Variables
- Frontend configuration: `kubernetes/frontend/configmap.yaml`
- Database config: `kubernetes/db/postgres-configmap.yaml`

### Resource Limits
Adjust CPU and memory requests/limits in each deployment based on your cluster capacity and requirements.

## Autoscaling

The frontend deployment includes HPA (Horizontal Pod Autoscaler) that scales based on:
- CPU utilization > 70%
- Memory utilization > 80%

Range: 3-10 replicas

## Scaling Individual Services

```bash
# Scale frontend to 5 replicas
kubectl scale deployment frontend-deployment --replicas=5 -n ecommerce

# Scale user service to 4 replicas
kubectl scale deployment user-service-deployment --replicas=4 -n ecommerce
```

## Health Checks

Each deployment includes:
- **Liveness Probe**: Restarts pod if health check fails
- **Readiness Probe**: Removes pod from service if not ready

Ensure your application endpoints implement:
- GET `/health` - Basic health check
- GET `/ready` - Readiness check

## Cleanup

```bash
# Delete entire namespace (deletes all resources)
kubectl delete namespace ecommerce

# Or delete individual components
kubectl delete -f kubernetes/frontend/
kubectl delete -f kubernetes/services/
kubectl delete -f kubernetes/db/
```

## Troubleshooting

### Pod stuck in Pending state
```bash
kubectl describe pod <pod-name> -n ecommerce
```

### Deployment not progressing
```bash
kubectl rollout status deployment/<deployment-name> -n ecommerce
kubectl rollout history deployment/<deployment-name> -n ecommerce
```

### Database connection issues
```bash
# Check if database is running
kubectl get statefulset postgres-statefulset -n ecommerce

# Test connection from a pod
kubectl exec -it <service-pod> -n ecommerce -- sh
# Inside pod: psql -h postgres-service -U postgres
```

## Best Practices

1. **Security**:
   - Use Secrets for sensitive data (passwords, API keys)
   - Implement RBAC and Network Policies
   - Use private container registries

2. **High Availability**:
   - Deploy replicas across multiple nodes
   - Use PodDisruptionBudgets
   - Implement proper health checks

3. **Monitoring**:
   - Add Prometheus/Grafana for metrics
   - Use centralized logging (ELK, EFK)
   - Set up alerts

4. **Cost Optimization**:
   - Use appropriate resource requests/limits
   - Enable Horizontal Pod Autoscaling
   - Use node affinity for cost optimization

## Additional Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [PostgreSQL Helm Chart](https://github.com/bitnami/charts/tree/main/bitnami/postgresql)
- [Best Practices for Running Stateful Applications](https://kubernetes.io/docs/tutorials/stateful-application/)
