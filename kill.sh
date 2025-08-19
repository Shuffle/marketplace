docker stack rm shuffle
docker service rm $(sudo docker service ls -q)
