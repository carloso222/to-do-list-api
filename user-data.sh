#!/bin/bash
# User data (decisión 5): AWS lo ejecuta UNA sola vez, como root, cuando se crea la instancia.
# La imagen de Ubuntu trae python3 pero NO trae venv ni pip, así que los instalamos aquí.
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip
