#!/bin/bash
sudo apt update -y &&
sudo apt install -y nginx
echo "instance 1" > /var/www/html/index.html