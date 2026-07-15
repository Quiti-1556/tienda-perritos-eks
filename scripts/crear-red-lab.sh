#!/bin/bash
set -e

PROJECT_NAME="red-lab"
REGION="us-east-1"

echo "====================================="
echo "Creando infraestructura de red AWS"
echo "====================================="

#####################################
# 1. VPC
#####################################
echo "1. VPC..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text)

if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc \
    --cidr-block 10.0.0.0/20 \
    --query 'Vpc.VpcId' \
    --output text)

  aws ec2 create-tags \
    --resources $VPC_ID \
    --tags Key=Name,Value=${PROJECT_NAME}-vpc

  aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \
    --enable-dns-hostnames "{\"Value\":true}"

  aws ec2 modify-vpc-attribute \
    --vpc-id $VPC_ID \
    --enable-dns-support "{\"Value\":true}"
fi

echo "VPC: $VPC_ID"

#####################################
# 2. INTERNET GATEWAY
#####################################
echo "2. IGW..."

IGW_ID=$(aws ec2 describe-internet-gateways \
 --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
 --query "InternetGateways[0].InternetGatewayId" \
 --output text)

if [ "$IGW_ID" == "None" ] || [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)

  aws ec2 attach-internet-gateway \
    --vpc-id $VPC_ID \
    --internet-gateway-id $IGW_ID

  aws ec2 create-tags \
    --resources $IGW_ID \
    --tags Key=Name,Value=${PROJECT_NAME}-igw
fi

echo "IGW: $IGW_ID"

#####################################
# 3. SUBNETS
#####################################
create_subnet() {
  NAME=$1
  CIDR=$2
  AZ=$3
  PUBLIC=$4

  SUBNET=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=$NAME" \
    --query "Subnets[0].SubnetId" \
    --output text)

  if [ "$SUBNET" == "None" ] || [ -z "$SUBNET" ]; then
    SUBNET=$(aws ec2 create-subnet \
      --vpc-id $VPC_ID \
      --cidr-block $CIDR \
      --availability-zone $AZ \
      --query 'Subnet.SubnetId' \
      --output text)

    aws ec2 create-tags \
      --resources $SUBNET \
      --tags Key=Name,Value=$NAME

    if [ "$PUBLIC" == "true" ]; then
      aws ec2 modify-subnet-attribute \
        --subnet-id $SUBNET \
        --map-public-ip-on-launch "{\"Value\":true}"
    fi
  fi

  echo $SUBNET
}

echo "3. Subnets..."

PUB_A=$(create_subnet "${PROJECT_NAME}-public-a" "10.0.0.0/24" "${REGION}a" true)
PUB_B=$(create_subnet "${PROJECT_NAME}-public-b" "10.0.1.0/24" "${REGION}b" true)

APP_A=$(create_subnet "${PROJECT_NAME}-app-a" "10.0.2.0/24" "${REGION}a" false)
APP_B=$(create_subnet "${PROJECT_NAME}-app-b" "10.0.3.0/24" "${REGION}b" false)

DATA_A=$(create_subnet "${PROJECT_NAME}-data-a" "10.0.4.0/24" "${REGION}a" false)
DATA_B=$(create_subnet "${PROJECT_NAME}-data-b" "10.0.5.0/24" "${REGION}b" false)

#####################################
# 4. NAT (Validación dinámica y espera)
#####################################
echo "4. NAT Gateway..."

EIP_ALLOC=$(aws ec2 describe-addresses \
 --query "Addresses[?Tags[?Value=='${PROJECT_NAME}-nat-eip']].AllocationId" \
 --output text)

if [ -z "$EIP_ALLOC" ] || [ "$EIP_ALLOC" == "None" ]; then
  EIP_ALLOC=$(aws ec2 allocate-address \
    --domain vpc \
    --query "AllocationId" \
    --output text)

  aws ec2 create-tags \
    --resources $EIP_ALLOC \
    --tags Key=Name,Value=${PROJECT_NAME}-nat-eip
fi

NAT_ID=$(aws ec2 describe-nat-gateways \
 --filter "Name=vpc-id,Values=$VPC_ID" \
 --query "NatGateways[?State!='deleted'].NatGatewayId | [0]" \
 --output text)

if [ "$NAT_ID" == "None" ] || [ -z "$NAT_ID" ]; then
  NAT_ID=$(aws ec2 create-nat-gateway \
    --subnet-id $PUB_A \
    --allocation-id $EIP_ALLOC \
    --query 'NatGateway.NatGatewayId' \
    --output text)
fi

echo "NAT ID detectado/creado: $NAT_ID"

# ESPERA CRÍTICA: Asegura que el NAT Gateway esté listo antes de continuar
echo "Esperando que el NAT Gateway esté en estado disponible (puede tardar de 1 a 3 minutos)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID" --region "$REGION"
echo "¡NAT Gateway listo y disponible!"

#####################################
# 5. ROUTE TABLE PUBLIC
#####################################
echo "5. Route table pública..."

RT_PUBLIC=$(aws ec2 create-route-table \
 --vpc-id $VPC_ID \
 --query 'RouteTable.RouteTableId' \
 --output text)

aws ec2 create-route \
 --route-table-id $RT_PUBLIC \
 --destination-cidr-block 0.0.0.0/0 \
 --gateway-id $IGW_ID || true

# Función auxiliar para asociar de manera segura y evitar "AlreadyAssociated"
safe_associate() {
  SUBNET_ID=$1
  ROUTE_TABLE_ID=$2

  # Verifica si la subred ya tiene una asociación explícita (distinta de la principal por defecto)
  EXISTING_ASSOC=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query "RouteTables[0].RouteTableId" \
    --output text)

  if [ "$EXISTING_ASSOC" == "None" ] || [ -z "$EXISTING_ASSOC" ]; then
    echo "Asociando subred $SUBNET_ID a la tabla $ROUTE_TABLE_ID..."
    aws ec2 associate-route-table --subnet-id "$SUBNET_ID" --route-table-id "$ROUTE_TABLE_ID" > /dev/null
  else
    echo "La subred $SUBNET_ID ya está asociada a la tabla $EXISTING_ASSOC (Omitiendo para evitar conflictos)."
  fi
}

safe_associate "$PUB_A" "$RT_PUBLIC"
safe_associate "$PUB_B" "$RT_PUBLIC"

#####################################
# 6. ROUTE TABLE PRIVATE
#####################################
echo "6. Route table privada..."

RT_PRIVATE=$(aws ec2 create-route-table \
 --vpc-id $VPC_ID \
 --query 'RouteTable.RouteTableId' \
 --output text)

# Ya no dará error, porque previamente esperamos a que el NAT_ID esté "available"
aws ec2 create-route \
 --route-table-id $RT_PRIVATE \
 --destination-cidr-block 0.0.0.0/0 \
 --nat-gateway-id $NAT_ID || true

for subnet in $APP_A $APP_B $DATA_A $DATA_B
do
 safe_associate "$subnet" "$RT_PRIVATE"
done

#####################################
# 7. VPC ENDPOINT S3
#####################################
echo "7. Endpoint S3..."

aws ec2 create-vpc-endpoint \
 --vpc-id $VPC_ID \
 --service-name com.amazonaws.${REGION}.s3 \
 --route-table-ids $RT_PRIVATE \
 || true

echo "====================================="
echo "INFRA CREADA EXITOSAMENTE"
echo "====================================="
echo "VPC: $VPC_ID"
echo "Publicas: $PUB_A / $PUB_B"
echo "Privadas APP: $APP_A / $APP_B"
echo "Privadas DATA: $DATA_A / $DATA_B"
echo "====================================="
