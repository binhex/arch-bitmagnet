# Application

[bitmagnet](https://github.com/bitmagnet-io/bitmagnet)

## Description

A self-hosted BitTorrent indexer, DHT crawler, content classifier and torrent
search engine with web UI, GraphQL API and Servarr stack integration.

## Build notes

Latest GitHub release.

## Usage

```bash
docker run -d \

    --name=<container name> \
    -p <webui port>:3333 \
    -p <bittorrent port tcp>:3344 \
    -p <bittorrent port udp>:3344/udp \
    -p <postgres port>:5432 \
    -v <path for config files>:/config \
    -v /etc/localtime:/etc/localtime:ro
    -e UMASK=<umask for created files> \
    -e PUID=<uid for user> \
    -e PGID=<gid for user> \

    binhex/arch-bitmagnet

```

Please replace all user variables in the above command defined by <> with the
correct values.

## Access application

`http://<host ip>:3333`

## Example

```bash
docker run -d \

    --name=bitmagnet \
    -p 3333:3333 \
    -p 3344:3344 \
    -p 3344:3344/udp \
    -p 5432:5432 \
    -v /apps/docker/bitmagnet:/config \
    -v /etc/localtime:/etc/localtime:ro \
    -e UMASK=000 \
    -e PUID=0 \
    -e PGID=0 \

    binhex/arch-bitmagnet

```

## Notes

User ID (PUID) and Group ID (PGID) can be found by issuing the following
command for the user you want to run the container as:-

```bash
id <username>

```

___
If you appreciate my work, then please consider buying me a beer  :D

[![PayPal donation](https://www.paypal.com/en_US/i/btn/btn_donate_SM.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=MM5E27UX6AUU4)

[Documentation](https://github.com/binhex/documentation) | [Support forum](https://forums.unraid.net/topic/174999-support-binhex-bitmagnet)
