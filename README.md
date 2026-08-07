1-
sudo wget -qO- https://raw.githubusercontent.com/GustavoLunaBH/Linux/main/Scripit/configure-netplan.sh | sed 's/\r$//' > configure-netplan.sh && chmod +x configure-netplan.sh && ./configure-netplan.sh

2-
sudo wget -qO- https://raw.githubusercontent.com/GustavoLunaBH/Linux/main/Scripit/setup-ad-primary.sh | sed 's/\r$//' > setup-ad-primary.sh && chmod +x setup-ad-primary.sh && ./setup-ad-primary.sh

3-
sudo wget -qO- https://raw.githubusercontent.com/GustavoLunaBH/Linux/main/Scripit/setup-ad-secondary.sh | sed 's/\r$//' > setup-ad-secondary.sh && chmod +x setup-ad-secondary.sh && ./setup-ad-secondary.sh

___________________________________________________________________________________________________

1 - sudo wget -qO- https://raw.githubusercontent.com/GustavoLunaBH/Linux/main/Scripit/configurar.sh | sed 's/\r$//' > configurar.sh
chmod +x configurar.sh
./configurar.sh


