Build Docker Image:

    cd /home/nils/quake2
    docker build -t r1q2-arena -f /home/nils/projects/q2server-dockerfile/Dockerfile .
    
Build Docker Image (OpenRA2):
    
    cd /home/nils/quake2
    docker build -t r1q2ded-openra2 -f ../projects/q2server-dockerfile/Dockerfile-openra2 .

Run Docker Container in interactive mode:

    docker run -it r1q2-arena
  
Run Docker Container in headless mode:

    docker run r1q2-arena
    
Run Docker Container (OpenRA2):

    docker run -e Q2_GAMEDIR=arena -e Q2_IP=localhost -e Q2_PORT=27912 -p 27912:27912/udp r1q2ded-openra2

Running with docker-compose

    cd ~/projects/q2server-dockerfile/
    docker-compose build
    docker-compose up -d
    docker-compose ps
    docker-compose logs -f
    docker ps
    docker-compose stop && docker-compose down
