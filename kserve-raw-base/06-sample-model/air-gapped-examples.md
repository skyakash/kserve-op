# KServe Air-Gapped Examples

If you are running in an air-gapped environment (no outbound internet access to `gs://` or `s3://`), the `sklearn-iris.yaml` example will fail when the KServe storage-initializer tries to download the model weights.

There are two primary ways to run inference offline in KServe:

---

## Method 1: Baked-in Model (Custom Container)
The most robust air-gapped method is to copy the model weights directly into your Docker image. You bypass the KServe storage-initializer entirely.

**1. Create a Dockerfile:**
```dockerfile
# Use the official KServe sklearn runtime
FROM kserve/sklearnserver:latest

# Create a local directory for the model
RUN mkdir -p /mnt/models

# COPY your locally downloaded model.joblib into the image
COPY model.joblib /mnt/models/

# The CMD is already defined in the base image
```

**2. Build & push to your internal private registry:**
```bash
docker build -t my-private-registry:5000/offline-iris:v1 .
docker push my-private-registry:5000/offline-iris:v1
```

**3. Deploy the InferenceService using the custom image:**
```yaml
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-iris-offline"
  annotations:
    serving.kserve.io/deploymentMode: "RawDeployment"
spec:
  predictor:
    containers:
      - name: kserve-container
        image: my-private-registry:5000/offline-iris:v1
        args:
          - --model_name=sklearn-iris
          - --model_dir=/mnt/models
```

---

## Method 2: Persistent Volume Claim (PVC)
If you don't want to bake models into an image, you can upload your models to a standard Kubernetes PVC and tell KServe to load the weights from there.

**1. Create a PVC in your namespace:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: offline-models-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
```

*(You must mount this PVC to a temporary pod first to copy your `model.joblib` into it).*

**2. Deploy the InferenceService pointing to the PVC:**
```yaml
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-iris-pvc"
  annotations:
    serving.kserve.io/deploymentMode: "RawDeployment"
spec:
  predictor:
    sklearn:
      # Pass the PVC name as a URI
      storageUri: "pvc://offline-models-pvc/sklearn/iris/1.0/model"
```
