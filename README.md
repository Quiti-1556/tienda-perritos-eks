# Descripción general
  
El proyecto tienda-perritos-eks es una implementación nativa de la nube de una aplicación web de tres capas, diseñada para ejecutarse en Amazon Elastic Kubernetes Service (EKS). Ofrece un ciclo de vida completo de extremo a extremo para una aplicación de "Tienda de Mascotas" (Pet Shop), que incluye el aprovisionamiento automatizado de la infraestructura mediante scripts de AWS CLI y un pipeline robusto de CI/CD utilizando GitHub Actions.  
  
El objetivo principal de este proyecto es demostrar un despliegue listo para producción de una pila contenedorizada (Frontend, Backend y Base de datos) aprovechando los servicios gestionados de AWS y la orquestación de Kubernetes.  
  
## Componentes del sistema
  
La aplicación está estructurada en tres capas distintas, cada una contenedorizada y gestionada como un despliegue de Kubernetes dentro del espacio de nombres tienda.    
  
Frontend: Un servidor web basado en Nginx que sirve una interfaz estática CRUD.  
  
Backend: Una API REST en Node.js (Express) que maneja la lógica de negocio y la comunicación con la base de datos.  
  
Database (Base de datos): Una instancia de MySQL 8 que proporciona almacenamiento persistente para los datos de los productos.  
  
## Infraestructura y Despliegue
  
El proyecto sigue una filosofía de "Infraestructura como Código" (IaC) utilizando scripts de shell para interactuar con la AWS CLI. El proceso de despliegue se divide en dos fases principales:  
1. Aprovisionamiento de la infraestructura  
  
Antes de que la aplicación pueda ejecutarse, se debe preparar el entorno subyacente de AWS. Esto incluye:  
  
Redes (Networking): Creación de una VPC con subredes públicas y privadas.  
  
Recursos base: Configuración de repositorios de ECR e instancias de EC2.  
  
Clúster EKS: Aprovisionamiento del plano de control (control plane) gestionado de Kubernetes y los nodos de trabajo (worker nodes).  
  
2. CI/CD de la aplicación  
  
El ciclo de vida de la aplicación es gestionado por el flujo de trabajo de CI/CD Tienda Perritos EKS.   
  
Este pipeline automatiza la construcción de imágenes de Docker, su envío (push) a Amazon Elastic Container Registry (ECR) y la actualización de los despliegues de Kubernetes.    
  
Para desplegar este proyecto tú mismo, necesitarás una cuenta de AWS y configurar los secretos de GitHub necesarios (por ejemplo, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, EKS_CLUSTER_NAME).
  
## Integrantes:
Brayan  Quitian
Alberto Zegers
Aron Acevedo