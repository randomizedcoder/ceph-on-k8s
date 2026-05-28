# nix/gitops/env/ceph-external-client.nix
#
# Registers a CephX user (`client.external` by default) with the Rook
# cluster so the external client0 microvm can mount CephFS.
#
# Build-time deterministic: the secret is produced offline by
# k8s-gen-secrets and lives in ./secrets/cephfs-client.secret.
#
# Emitted Kubernetes objects:
#
#   1. Secret/cephfs-client-secret (ns rook-ceph)
#        stringData.key = <base64 secret>
#      The same key that the client microvm's keyring uses.
#
#   2. Job/ceph-auth-import-external (ns rook-ceph, sync-wave 2)
#        Uses the `quay.io/ceph/ceph` image (already pulled on every
#        node by rook-ceph-tools). Mounts the same admin keyring
#        Secret that the toolbox uses, builds a working
#        /etc/ceph/keyring + ceph.conf, then runs
#        `ceph auth import` + `ceph auth caps`.
#
# Idempotent: `ceph auth import` of the same (name, key) pair is a
# no-op, and `ceph auth caps` overwrites — safe to re-run on every
# cluster rebuild.
#
{ pkgs, lib, secrets }:
let
  constants = import ../../constants.nix;
  cu = constants.ceph.externalClient;

  haveSecret = secrets.cephClientSecret != null;
in
{
  manifests = lib.optionals haveSecret [
    {
      name = "ceph-external-client/secret.yaml";
      content = ''
        apiVersion: v1
        kind: Secret
        metadata:
          name: cephfs-client-secret
          namespace: ${constants.ceph.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        type: Opaque
        stringData:
          key: ${secrets.cephClientSecret}
      '';
    }

    {
      name = "ceph-external-client/job.yaml";
      content = ''
        apiVersion: batch/v1
        kind: Job
        metadata:
          name: ceph-auth-import-${cu.user}
          namespace: ${constants.ceph.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "2"
        spec:
          backoffLimit: 30
          ttlSecondsAfterFinished: 600
          template:
            metadata:
              labels:
                app: ceph-auth-importer
            spec:
              restartPolicy: OnFailure
              containers:
              - name: importer
                # Same image rook-ceph-tools uses — already pulled on
                # every node, has bash + ceph CLI.
                image: quay.io/ceph/ceph:v19.2.3
                env:
                - name: CEPH_USER_KEY
                  valueFrom:
                    secretKeyRef:
                      name: cephfs-client-secret
                      key: key
                command: ["bash", "-euxc"]
                args:
                - |
                  # Build /etc/ceph/{ceph.conf,keyring} from the same
                  # admin Secret that the toolbox uses. The ceph-config
                  # volume is emptyDir so we have somewhere to write.
                  MON_HOSTS=$(awk -F= '{print $NF}' /etc/rook/mon-endpoints)
                  cat > /etc/ceph/ceph.conf <<EOF
                  [global]
                  mon_host = $MON_HOSTS
                  EOF
                  cat > /etc/ceph/keyring <<EOF
                  [client.admin]
                  	key = $(cat /var/lib/rook-ceph-mon/secret.keyring)
                  EOF

                  # Build the external client's keyring file inline
                  # from the Secret value. Caps are included so that
                  # `ceph auth import` registers the user + caps in one
                  # call (the alternative path, `ceph auth caps` after
                  # import, is also fine and idempotent — but `import`
                  # rejects keyrings without caps).
                  cat > /tmp/external.keyring <<EOF
                  [client.${cu.user}]
                  	key = $CEPH_USER_KEY
                  	caps mon = "allow r fsname=${cu.fsName}"
                  	caps mds = "allow rw fsname=${cu.fsName}"
                  	caps osd = "allow rw tag cephfs data=${cu.fsName}"
                  EOF

                  ceph auth import -i /tmp/external.keyring

                  # Ensure caps stay current even after re-runs where
                  # someone has manually edited them.
                  ceph auth caps client.${cu.user} \
                    mon "allow r fsname=${cu.fsName}" \
                    mds "allow rw fsname=${cu.fsName}" \
                    osd "allow rw tag cephfs data=${cu.fsName}"

                  # Verification — fail the Job if the user didn't land.
                  ceph auth get client.${cu.user}
                volumeMounts:
                - { name: ceph-config,   mountPath: /etc/ceph }
                - { name: mon-endpoints, mountPath: /etc/rook }
                - { name: admin-secret,  mountPath: /var/lib/rook-ceph-mon, readOnly: true }
              volumes:
              - name: ceph-config
                emptyDir: {}
              - name: mon-endpoints
                configMap:
                  name: rook-ceph-mon-endpoints
                  items:
                  - { key: data, path: mon-endpoints }
              - name: admin-secret
                secret:
                  secretName: rook-ceph-mon
                  items:
                  - { key: ceph-secret, path: secret.keyring }
      '';
    }

    {
      name = "ceph-external-client/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: ceph-external-client
          namespace: argocd
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/ceph-external-client
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
              - CreateNamespace=false
      '';
    }
  ];
}
