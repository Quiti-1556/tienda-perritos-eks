#!/bin/bash
set -e

REGION="us-east-1"
CLUSTER_NAME="tienda-perritos-eks"
NODEGROUP_NAME="tienda-node-eks"

echo "====================================="
echo " CREANDO EKS "
echo "====================================="

# 1. DETECTAR ROLES DINÁMICAMENTE EN TU CUENTA DEL LABORATORIO
echo "Buscando roles de IAM activos en la cuenta..."

CLUSTER_ROLE_ARN=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'EksClusterRole') || contains(RoleName, 'LabEksClusterRole')].Arn" \
  --output text | head -n 1)

NODE_ROLE_ARN=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, 'EksNodeRole') || contains(RoleName, 'LabEksNodeRole')].Arn" \
  --output text | head -n 1)

# Validación por si el laboratorio usa el rol estándar de AWS Academy "LabRole"
if [ -z "$CLUSTER_ROLE_ARN" ] || [ "$CLUSTER_ROLE_ARN" == "None" ] || [ "$CLUSTER_ROLE_ARN" == "" ]; then
  echo "⚠️ No se encontró un rol específico de EKS Cluster. Usando LabRole de respaldo..."
  CLUSTER_ROLE_ARN="arn:aws:iam::817495613744:role/LabRole"
fi

if [ -z "$NODE_ROLE_ARN" ] || [ "$NODE_ROLE_ARN" == "None" ] || [ "$NODE_ROLE_ARN" == "" ]; then
  echo "⚠️ No se encontró un rol específico de EKS Node. Usando LabRole de respaldo..."
  NODE_ROLE_ARN="arn:aws:iam::817495613744:role/LabRole"
fi

echo "-> CLUSTER_ROLE_ARN: $CLUSTER_ROLE_ARN"
echo "-> NODE_ROLE_ARN: $NODE_ROLE_ARN"

# =====================================
# CONFIGURACIÓN DE RED ASOCIADA
# =====================================

# Buscar VPC
VPC_ID=$(aws ec2 describe-vpcs \
 --filters "Name=tag:Name,Values=red-lab-vpc" \
 --query "Vpcs[0].VpcId" \
 --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
  echo "❌ Error: No se encontró la VPC 'red-lab-vpc'. Asegúrate de correr el script de red primero."
  exit 1
fi
echo "VPC Encontrada: $VPC_ID"

# ⚠️ CORRECCIÓN CRÍTICA: Filtrar únicamente las subredes privadas de aplicación (APP) para los Nodos
echo "Buscando subredes privadas de aplicación para el Node Group..."
SUBNETS_APP=$(aws ec2 describe-subnets \
 --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*app*" \
 --query "Subnets[*].SubnetId" \
 --output text)

# También buscamos las subredes públicas para que el clúster (control plane) pueda asociar balanceadores
SUBNETS_PUB=$(aws ec2 describe-subnets \
 --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*public*" \
 --query "Subnets[*].SubnetId" \
 --output text)

# Juntamos todas para el Cluster (EKS requiere públicas y privadas para su comunicación interna)
ALL_SUBNETS="$SUBNETS_APP $SUBNETS_PUB"

echo "Subredes para el Clúster: $ALL_SUBNETS"
echo "Subredes exclusivas para los Nodos (App): $SUBNETS_APP"

# Security Group para el tráfico de control
SG_ID=$(aws ec2 describe-security-groups \
 --filters "Name=group-name,Values=SG-EKS" \
 --query "SecurityGroups[0].GroupId" \
 --output text)

if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
 SG_ID=$(aws ec2 create-security-group \
  --group-name SG-EKS \
  --description "EKS Security Group" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

 aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol -1 \
  --cidr 0.0.0.0/0
fi

echo "SG: $SG_ID"

#######################################
# EKS CLUSTER
#######################################
STATUS=$(aws eks list-clusters \
 --query "clusters[?@=='$CLUSTER_NAME']" \
 --output text)

# Convertimos la lista de subredes separadas por espacio a formato separado por comas
SUBNETS_COMMA=$(echo $ALL_SUBNETS | tr ' ' ',')

if [ -z "$STATUS" ]; then
 echo "Creando cluster..."
 aws eks create-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --role-arn $CLUSTER_ROLE_ARN \
  --resources-vpc-config subnetIds=$SUBNETS_COMMA,securityGroupIds=$SG_ID,endpointPublicAccess=true,endpointPrivateAccess=true

 echo "Esperando cluster ACTIVE (esto puede tardar de 5 a 10 minutos)..."
 aws eks wait cluster-active \
  --name $CLUSTER_NAME
fi

#######################################
# NODE GROUP
#######################################
NODE_EXISTS=$(aws eks list-nodegroups \
 --cluster-name $CLUSTER_NAME \
 --query "nodegroups[?@=='$NODEGROUP_NAME']" \
 --output text)

if [ -z "$NODE_EXISTS" ]; then
 echo "Creando Node Group en subredes privadas de aplicación..."
 aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $NODEGROUP_NAME \
  --node-role $NODE_ROLE_ARN \
  --subnets $SUBNETS_APP \
  --scaling-config minSize=1,maxSize=3,desiredSize=1 \
  --instance-types t3.large \
  --capacity-type SPOT

 echo "Esperando Node Group ACTIVE..."
 aws eks wait nodegroup-active \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $NODEGROUP_NAME
fi

#######################################
# TAGS PARA LOAD BALANCER
#######################################
echo "Agregando tags para el AWS Load Balancer Controller..."
for subnet in $ALL_SUBNETS
do
 aws ec2 create-tags \
  --resources $subnet \
  --tags \
  Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared \
  Key=kubernetes.io/role/elb,Value=1
done

echo "====================================="
echo "EKS LISTO"
echo "====================================="
echo "CLUSTER: $CLUSTER_NAME"
echo "NODEGROUP: $NODEGROUP_NAME"
