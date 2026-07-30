# simplifier le repos:

## objectif: 
- simplifier le repos avec juste le deploiment des composes. 
-  un ansible pour instaler les element de base sur le serveur : 1-base_setup.yml mais aves les roles base_setup node_exporter alloy docker ufw gnoland
- aucun secrets ne doit etre generer par le ansible 

 voila les compose que je souhaite avoir en deploiement  et il doivent tous etre configurable par un .env  comme pour le compose snapshot: 

 ### sentry-alone : 

 ```bash 
    services:
    sentry:
        image: "${IMAGES}"
        restart: on-failure
        ports:
        - 26656:26656
        - 26657:26657
        volumes:
        - ./entrypoint.sh:/entrypoint.sh:ro
        - ./config.toml:/gnoroot/config.toml:ro
        - ./genesis.json:/gnoroot/gnoland-data/genesis.json:ro
        - ./gnoland-data:/gnoroot/gnoland-data
        entrypoint: /entrypoint.sh
        environment:
        MONIKER: 
        SEEDS: "${SEEDS}"
        PERSISTENT_PEERS: "${PERSISTENT_PEERS}"
        PRIVATE_PEER_IDS: "g1tfwayqjjdh2u6xxejk93jqut5jmlkyzwa0znkv,g1x58y6xjgzgtjm9keau3q8mn7kgs72k0pkj5h6c" # #p2p_address of validator
```
#### .env :

IMAGES=
SEEDS=
PERSISTENT_PEERS=
PRIVATE_PEER_IDS=

---

### validator alone : 

 ```bash 
    services:
    sentry:
        image: "${IMAGES}"
        restart: on-failure
        ports:
        - 26656:26656
        - 26657:26657
        volumes:
        - ./entrypoint.sh:/entrypoint.sh:ro
        - ./config.toml:/gnoroot/config.toml:ro
        - ./genesis.json:/gnoroot/gnoland-data/genesis.json:ro
        - ./gnoland-data:/gnoroot/gnoland-data
        entrypoint: /entrypoint.sh
        environment:
        MONIKER: 
        SEEDS: "${SEEDS}"
        PERSISTENT_PEERS: "${PERSISTENT_PEERS}"
        PRIVATE_PEER_IDS: "g1tfwayqjjdh2u6xxejk93jqut5jmlkyzwa0znkv,g1x58y6xjgzgtjm9keau3q8mn7kgs72k0pkj5h6c" # #p2p_address of validator
```