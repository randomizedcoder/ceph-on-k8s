# nix/gitops/env/cert-manager.nix
#
# cert-manager — issues TLS certs for Ingress resources.
#
# Ships one ClusterIssuer:
#   `selfsigned-lab` — in-cluster CA, used by phase-1 lab Ingress (Ceph
#   dashboard, RGW S3 endpoint). Browsers will warn on first visit;
#   one-time cert-trust to make the warning go away.
#
# Task #7 will add a second `cluster-ca` ClusterIssuer backed by the
# build-time PKI's cluster CA (the same one every node trusts for
# apiserver, etcd, etc.) so the dashboard and S3 endpoint can be issued
# certs from a CA that the dev box already trusts.
#
# Upstream cert-manager.yaml is applied verbatim — we don't patch it. It
# contains the CRDs, operator Deployment, webhook, cainjector, and RBAC.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;

  upstreamManifest = pkgs.fetchurl {
    url  = constants.certManager.url;
    hash = constants.certManager.hash;
  };
in
{
  manifests = [
    {
      name = "cert-manager/upstream.yaml";
      source = "${upstreamManifest}";
    }

    # ClusterIssuers — rely on the CRDs in upstream.yaml. Sync-wave 1 so
    # the CRD lands before these.
    {
      name = "cert-manager/issuers.yaml";
      content = ''
        ---
        # A bootstrap "selfsigned" issuer lets us sign a root cert that
        # becomes the in-cluster CA. Ingress resources then reference
        # `selfsigned-lab` as their cluster-issuer.
        apiVersion: cert-manager.io/v1
        kind: ClusterIssuer
        metadata:
          name: selfsigned-bootstrap
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          selfSigned: {}
        ---
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: selfsigned-lab-ca
          namespace: cert-manager
          annotations:
            argocd.argoproj.io/sync-wave: "2"
        spec:
          isCA: true
          commonName: selfsigned-lab-ca
          secretName: selfsigned-lab-ca-cert
          duration: 87600h0m0s   # 10y
          privateKey:
            algorithm: ECDSA
            size: 256
          issuerRef:
            name: selfsigned-bootstrap
            kind: ClusterIssuer
            group: cert-manager.io
        ---
        apiVersion: cert-manager.io/v1
        kind: ClusterIssuer
        metadata:
          name: selfsigned-lab
          annotations:
            argocd.argoproj.io/sync-wave: "3"
        spec:
          ca:
            secretName: selfsigned-lab-ca-cert
      '';
    }

    {
      name = "cert-manager/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: cert-manager
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/cert-manager
            directory:
              recurse: false
              exclude: 'application.yaml'
          destination:
            server: https://kubernetes.default.svc
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - ServerSideApply=true
              - CreateNamespace=true
      '';
    }
  ];
}
