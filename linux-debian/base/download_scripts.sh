#!/bin/bash
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_docker.sh -O /opt/scripts/install_docker.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_mise.sh -O /opt/scripts/install_mise.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_npm.sh -O /opt/scripts/install_npm.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_opentofu.sh -O /opt/scripts/install_opentofu.sh
wget https://raw.githubusercontent.com/nchekwa/vsce/refs/heads/main/src/scripts/install_pulumi.sh -O /opt/scripts/install_pulumi.sh
chmod +x /opt/scripts/*.sh
