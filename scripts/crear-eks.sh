#!/bin/bash
set -e

REGION="us-east-1"
CLUSTER_ROLE_ARN="arn:aws:iam::572446332677:role/c220459a5559967l15877993t1w572446-LabEksClusterRole-ke1rLIJEv8TJ"
NODE_ROLE_ARN="arn:aws:iam::572446332677:role/c220459a5559967l15877993t1w572446332-LabEksNodeRole-8jiB15nZfCGE"
CLUSTER_NAME="tienda-perritos-eks"
NODEGROUP_NAME="tienda-node-eks"

echo "====================================="
echo " CREANDO EKS "
echo "====================================="

# Buscar VPC

VPC_ID=$(aws ec2 describe-vpcs \
 --filters "Name=tag:Name,Values=red-lab-vpc" \
 --query "Vpcs[0].VpcId" \
 --output text)

echo "VPC: $VPC_ID"

# Buscar subnets

SUBNETS=$(aws ec2 describe-subnets \
 --filters "Name=vpc-id,Values=$VPC_ID" \
 --query "Subnets[*].SubnetId" \
 --output text)

echo "SUBNETS: $SUBNETS"

# Security Group

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

if [ -z "$STATUS" ]; then

 echo "Creando cluster..."

 aws eks create-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --role-arn $CLUSTER_ROLE_ARN \
  --resources-vpc-config subnetIds=$(echo $SUBNETS | tr ' ' ','),securityGroupIds=$SG_ID,endpointPublicAccess=true,endpointPrivateAccess=true

 echo "Esperando cluster ACTIVE..."

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

 echo "Creando Node Group..."

 aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $NODEGROUP_NAME \
  --node-role $NODE_ROLE_ARN \
  --subnets $SUBNETS \
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

for subnet in $SUBNETS
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
