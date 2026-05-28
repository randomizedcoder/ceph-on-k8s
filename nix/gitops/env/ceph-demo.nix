# nix/gitops/env/ceph-demo.nix
#
# Tiny proof-of-concept workload demonstrating all three Ceph
# StorageClasses from a single pod:
#
#   - ceph-block       (RBD, RWO, ext4)
#   - ceph-filesystem  (CephFS, RWX)
#   - ceph-bucket      (S3 via ObjectBucketClaim → Secret + ConfigMap)
#
# Sync-wave 1 so this lands after the CephCluster's StorageClasses
# (chart wave 0). The CephCluster's `phase=Ready` wait in
# gitops-bootstrap-module.nix gates the demo's actual bind time:
# the PVCs/OBC will pend until OSDs/RGW are up, then bind.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;
in
{
  manifests = [
    {
      name = "ceph-demo/pvcs.yaml";
      content = ''
        # RBD block volume (RWO)
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: ceph-block-test
          namespace: ceph-demo
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          storageClassName: ceph-block
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 1Gi
        ---
        # CephFS shared filesystem (RWX)
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: ceph-fs-test
          namespace: ceph-demo
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          storageClassName: ceph-filesystem
          accessModes: [ReadWriteMany]
          resources:
            requests:
              storage: 1Gi
        ---
        # S3 bucket via ObjectBucketClaim — Rook's bucket-provisioner
        # creates a bucket in RGW and emits a Secret + ConfigMap with
        # the same name as the OBC, holding the access key/secret
        # (Secret) and the bucket host/port/name (ConfigMap).
        apiVersion: objectbucket.io/v1alpha1
        kind: ObjectBucketClaim
        metadata:
          name: ceph-s3-test
          namespace: ceph-demo
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          storageClassName: ceph-bucket
          generateBucketName: ceph-demo
      '';
    }
    {
      name = "ceph-demo/workload.yaml";
      content = ''
        # Smoke pod that mounts both PVCs and exposes the OBC creds.
        # `sleep infinity` on first boot; the user runs validation
        # commands via `kubectl exec`. See README's "Quick start"
        # section for the canonical smoke test.
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: ceph-smoke
          namespace: ceph-demo
          annotations:
            argocd.argoproj.io/sync-wave: "1"
          labels:
            app: ceph-smoke
        spec:
          replicas: 1
          strategy:
            type: Recreate
          selector:
            matchLabels:
              app: ceph-smoke
          template:
            metadata:
              labels:
                app: ceph-smoke
            spec:
              containers:
              - name: smoke
                image: busybox:1.37
                command: ["/bin/sh", "-c", "sleep infinity"]
                envFrom:
                # OBC-provided AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY
                - secretRef:
                    name: ceph-s3-test
                    optional: true
                # OBC-provided BUCKET_HOST + BUCKET_NAME + BUCKET_PORT
                # + BUCKET_REGION + BUCKET_SUBREGION
                - configMapRef:
                    name: ceph-s3-test
                    optional: true
                volumeMounts:
                - name: block
                  mountPath: /data/block
                - name: fs
                  mountPath: /data/fs
                resources:
                  requests:
                    cpu: 10m
                    memory: 32Mi
                  limits:
                    memory: 64Mi
              volumes:
              - name: block
                persistentVolumeClaim:
                  claimName: ceph-block-test
              - name: fs
                persistentVolumeClaim:
                  claimName: ceph-fs-test
      '';
    }
    {
      name = "ceph-demo/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: ceph-demo
          namespace: argocd
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/ceph-demo
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
