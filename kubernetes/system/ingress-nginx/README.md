# NGINX Ingress Controller

See the [main README](../../../README.md#ingress-nginx) for full documentation, installation steps, and troubleshooting.

<!-- TODO: evaluate MetalLB to replace NodePort
     MetalLB assigns a virtual IP to LoadBalancer services and handles the :80/:443 mapping,
     eliminating the need to pass explicit ports. Steps:
       1. Install MetalLB (helm or manifest)
       2. Configure an IPAddressPool with a free IP range on the local network
       3. Change service.type from NodePort to LoadBalancer in values.yaml
       4. Remove the nodePorts block
     Reference: https://metallb.universe.tf/installation/
-->
