Build Docker Image:

    cd /home/quake2/quake2
    docker build -t r1q2-arena -f /home/nils/projects/q2server-dockerfile/Dockerfile .

Run Docker Container in interactive mode:

    docker run -it r1q2-arena
  
Run Docker Container in headless mode:

    docker run r1q2-arena

Running with docker-compose

    cd ~/projects/q2server-dockerfile/
    docker-compose build
    docker-compose up -d
    docker-compose ps
    docker-compose logs -f
    docker ps
    docker-compose stop && docker-compose down