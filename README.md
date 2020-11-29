Docker Image bauen:
  cd /home/quake2/quake2
  docker build -t r1q2-arena -f /home/nils/projects/q2server-dockerfile/Dockerfile .

Docker Container im interactive mode ausführen:
  docker run -it r1q2-arena
  
Docker Container im headless mode ausführen:
  docker run r1q2-arena