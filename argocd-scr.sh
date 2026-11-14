#!/bin/bash

# this script is used to install the ArgoCD application if needed

kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"NodePort"}}'

# print the ArgoCD server URL and the initial admin password
until kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; do
    echo "Waiting for ArgoCD initial admin secret..."
    sleep 4
done

ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
ARGOCD_SERVER_URL=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[0].nodePort}')

echo "ArgoCD server URL: http://localhost:${ARGOCD_SERVER_URL}"
echo "ArgoCD initial admin password: ${ARGOCD_ADMIN_PASSWORD}"


