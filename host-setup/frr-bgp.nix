# host-setup/frr-bgp.nix
#
# OPTIONAL: NixOS module fragment for running FRR's bgpd on the host as
# a BGP peer for the ceph-on-k8s cluster's Cilium BGPControlPlane.
#
# The default ceph-on-k8s setup uses a static `ip route` on the host
# bridge (installed by `nix run .#k8s-network-setup`) to make the pod
# CIDR reachable through cp0. That is sufficient for the lab and is
# what the rest of the docs assume.
#
# Importing this module replaces the static route with a real BGP
# session: each of the 4 cluster nodes (cp0/cp1/cp2/w3) opens an
# eBGP session to the host and announces the pod-IP slice it has been
# allocated by Cilium's multi-pool IPAM (a /24 from the `default` pool
# + a /32 from `ceph-mon`). FRR's RIB picks the per-prefix best path,
# so a single-node outage doesn't blackhole the whole pod CIDR.
#
# To use:
#
#   # /etc/nixos/configuration.nix (host)
#   { ... }: {
#     imports = [ /path/to/ceph-on-k8s/host-setup/frr-bgp.nix ];
#   }
#
#   sudo nixos-rebuild switch
#
# Then remove the static route the network-setup script installed:
#
#   sudo ip route del 10.244.0.0/16
#   sudo nix run .#k8s-network-setup     # add the bridge/TAPs without
#                                        # the route — see comment in
#                                        # nix/network-setup.nix
#
# Verify BGP sessions are up:
#
#   sudo vtysh -c 'show bgp ipv4 unicast summary'
#   # Expect 4 neighbors in state "Established", each advertising a
#   # /24 from 10.244.0.0/16 (their default pool slice) + 1 /32 from
#   # 10.244.99.0/29 (their MON in the ceph-mon pool, if any).

{ ... }:
{
  # bgpd, zebra, vtysh. zebra is mandatory — bgpd injects routes into
  # the kernel's main table via zebra's rib.
  services.frr.zebra.enable = true;
  services.frr.bgpd.enable  = true;

  # ASNs (private):
  #   host:    64513   (this side)
  #   cluster: 64512   (cilium-agent on each node)
  #
  # Peer addresses are the cluster node IPs on the k8sbr0 bridge.
  # Cilium's BGPClusterConfig has `peerAddress = 10.33.33.1`
  # (the bridge IP / gateway4 in constants.nix), so on the host side
  # we listen on the bridge and peer back to each node.
  services.frr.bgpd.config = ''
    router bgp 64513
      bgp router-id 10.33.33.1
      no bgp default ipv4-unicast

      neighbor cluster peer-group
      neighbor cluster remote-as 64512
      neighbor cluster timers 10 30
      neighbor cluster timers connect 5

      neighbor 10.33.33.10 peer-group cluster
      neighbor 10.33.33.11 peer-group cluster
      neighbor 10.33.33.12 peer-group cluster
      neighbor 10.33.33.13 peer-group cluster

      address-family ipv4 unicast
        neighbor cluster activate
        neighbor cluster soft-reconfiguration inbound
        ! Accept only the pod CIDR (10.244.0.0/16) and its sub-prefixes
        ! to avoid the cluster nodes also advertising e.g. Service IPs.
        neighbor cluster prefix-list allow-pod-cidr in
      exit-address-family
    !
    ip prefix-list allow-pod-cidr seq 10 permit 10.244.0.0/16 le 32
    ip prefix-list allow-pod-cidr seq 99 deny any
  '';

  # Firewall: bgpd listens on TCP/179.
  networking.firewall.allowedTCPPorts = [ 179 ];
}
