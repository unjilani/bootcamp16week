1- Create ECR repository
2- AWS Cli configure
3- Build custom image , tag it and push to AWS ECR repository (make sure S3 bucket is configured already on AWS else create one to store images)
4- Create RDS postgres database 
5- Create ECS clutser
6- Create Task definition with custom image path on ECR / and use environment variable to define for RDS database credentials
7- Create Service inlclude Application Load balancer with listener port 80 and Traffic port 8000
8- Make sure SG correctly define 



# Testing locally
# Run PostgreSQL container
docker run -d \
 --name attendance-db \
 -e POSTGRES_PASSWORD=password \
 -e POSTGRES_DB=mydb \
 -p 5432:5432 \
 postgres:15

# Export database connection string
export DB_LINK="postgresql://postgres:password@localhost:5432/mydb"

# cd to src

cd src

# Virtual env

python3 -m venv venv

source venv/bin/activate

pip install -r requirements.txt


## Building with docker bake

-login to ecr 
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 366140438193.dkr.ecr.ap-south-1.amazonaws.com

Docker buildx bake app --push 