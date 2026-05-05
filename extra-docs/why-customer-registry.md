# Why `--customer-registry` Exists (and Can't Be Replaced at Deploy Time)

## The question

> Why do we rewrite image references in the OLM bundle at **build time** instead of letting the customer override them at **deploy time**?

## Short answer

Because OLM treats the bundle image as immutable. The customer's `kubectl apply` or `operator-sdk run bundle` has no clean hook to substitute image references. By the time the bundle reaches the customer's cluster, the image refs are already locked in. We rewrite at build time so that what arrives on the customer cluster Just Works.

## Where image refs live

A built operator publishes two artifacts to the build registry:

| Artifact | What it is |
|---|---|
| **Operator image** (`<reg>/<name>:<tag>`) | The actual controller binary, packaged in a container |
| **Bundle image** (`<reg>/<name>:<tag>-bundle`) | A container image whose layers are CSV + CRDs + metadata YAML files |

Image references live in three places, all baked at build time:

```
operator-deployment.yaml
  └─ spec.template.spec.containers[0].image       ← references the operator image

bundle/manifests/<name>.clusterserviceversion.yaml   (inside the bundle image)
  ├─ spec.install.spec.deployments[0]...containers[0].image   ← operator image
  └─ relatedImages[].image                                     ← all images OLM should pre-pull
```

The CSV and the operator-deployment YAML are static text files. Once `make bundle` runs and pushes the bundle image, those text files are sealed inside a container layer.

## Why OLM treats them as immutable

OLM consumes the bundle image like any other container: it pulls the layers, reads the embedded CSV, and applies the deployments described inside. There is no mechanism in OLM's design to:

- Edit the CSV's `image:` fields between pull and apply
- Override `spec.install...image` on the command line
- Substitute `relatedImages` at install time

This is intentional. OLM's model of an operator is "what's in the bundle is the authoritative description of this operator version." Letting the user mutate it would break upgrade semantics, signature verification, and reproducibility.

A few things that look like they might help, but don't:

| Apparent option | Why it doesn't work |
|---|---|
| `operator-sdk run bundle --override-image` | **No such flag exists.** operator-sdk does not support image substitution at install time. |
| Patching the CSV after deploy (`kubectl edit csv`) | OLM treats the CSV as a snapshot of the bundle. Edits get reverted by the next reconcile. |
| Mounting a different bundle image with the same tag | The bundle is pulled by digest/tag once; the operator-deployment is created from the embedded CSV. Even if you swap the image at the registry, OLM has already extracted what it needs. |
| Pre-pulling the operator image to a node and tagging it locally | kubelet pulls by registry name. Local cache only helps if the name matches the CSV exactly — defeated by `imagePullPolicy: Always` and by names that don't resolve at all in air-gapped clusters. |

## The one real deploy-time alternative: cluster-level mirror configuration

OpenShift (and CRI-O-based clusters) supports a cluster-scoped CRD called `ImageDigestMirrorSet` (formerly `ImageContentSourcePolicy`):

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: kserve-operator-mirror
spec:
  imageDigestMirrors:
    - source: docker.io/akashneha
      mirrors:
        - registry.customer.internal/mirrors/akashneha
```

With this in place, the cluster's container runtime transparently rewrites every pull of `docker.io/akashneha/*` → `registry.customer.internal/mirrors/akashneha/*`. The bundle's image refs **don't need to change** — the cluster intercepts them.

### Why we don't rely on this

`ImageDigestMirrorSet` works only when:

1. The cluster runs **CRI-O** (OpenShift) or **containerd** with mirror config — not vanilla Docker
2. The cluster admin has **already configured** the mirror entries before the operator is installed
3. The mirrored images keep the **same digest** as the originals (which our `mirror-images.sh` does, but third-party mirrors may not)

Most enterprise customers on vanilla Kubernetes (EKS, GKE, AKS, kubeadm, kind) cannot use this. They need the bundle's image refs to point at their registry directly.

## What `--customer-registry` does instead

At generation time, `generate-kserve-operator.sh --customer-registry <prefix>`:

1. Rewrites `image:` fields in `operator-deployment.yaml` → `<prefix>/<name>:<tag>`
2. Rewrites the CSV inside `bundle/manifests/` → same
3. Generates a `mirror-images.sh` helper (skopeo-based) that copies the operator + bundle images from the build registry to the customer registry
4. Generates a `deploy-bundle.sh` helper that walks the customer through `operator-sdk run bundle` against the rewritten bundle image

The customer's flow becomes:
- `bash mirror-images.sh --archive` (builder side, with internet)
- transfer the package + tar files (USB / secure gateway)
- `bash mirror-images.sh --load --user … --pass …` (customer side, into their registry)
- `bash setup-credentials.sh --user … --pass …` (pull secrets)
- `bash deploy-bundle.sh` (or `operator-sdk run bundle <prefix>/<name>:<tag>-bundle`)

Everything the cluster pulls now resolves inside the customer's network. No external dependency at install time.

## Decision criteria

Use `--customer-registry`:
- Customer cluster cannot reach the build registry (air-gapped, restricted egress, internal network only)
- Customer policy requires images served from their own registry
- Customer cluster runs vanilla Kubernetes (no `ImageDigestMirrorSet` support)
- Customer wants OLM upgrade lifecycle but rejects external dependencies at install time

Skip `--customer-registry` (rely on direct pulls or cluster mirroring):
- Customer is on OpenShift with a configured `ImageDigestMirrorSet`
- Customer cluster has open egress to the build registry and that's acceptable to security review
- The build registry is acceptable as a permanent dependency (rare in enterprise)

For an air-gapped enterprise customer, `--customer-registry` is the right answer. There is no equivalent that works at deploy time.
