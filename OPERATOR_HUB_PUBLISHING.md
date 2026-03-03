# Publishing Your KServe Operator to OperatorHub

Currently, you have generated a raw **OLM bundle image**. This bundle lets anyone install the operator *locally* if they add it to their own private registry and create their own `CatalogSource`. 

However, to make your operator publicly visible correctly in the Web UI of `OperatorHub.io` (and Red Hat OpenShift's internal OperatorHub), you need to officially submit your bundle manifests to the community!

---

## 🚀 How to Publish to the Public OperatorHub

Follow these official steps to push the operator to the open-source community:

### 1. Ensure Metadata is Complete
Double-check your generated bundle YAML to ensure your maintainer info, icon, and description are accurate:
```bash
# Check the generated bundle's ClusterServiceVersion (CSV)
cat bundle/manifests/kserve-raw-operator.clusterserviceversion.yaml
```

### 2. Fork the Community Repository
OperatorHub manually reviews community operators. You need to fork their central repository on GitHub:
- Go to [https://github.com/k8s-operatorhub/community-operators](https://github.com/k8s-operatorhub/community-operators) and fork it.

### 3. Add your Bundle to the Fork
Clone your fork locally, and add a new directory for your operator under `operators/`:
```bash
git clone https://github.com/<your-username>/community-operators
cd community-operators

# create a directory for your operator and version
mkdir -p operators/kserve-raw-operator/0.1.0/

# copy your generated bundle contents inside
cp -r /path/to/kserve-op/p-kserve-operator/bundle/* operators/kserve-raw-operator/0.1.0/
```

### 4. Test the Submission Locally
OperatorHub provides a testing tool called `opm` (Operator Package Manager). It ensures your bundle follows standards before you open a Pull Request.
If you don't have it, CI will test it, but you can also download and run it locally.

### 5. Create a Pull Request (PR)
1. Commit the new operator folders to your branch.
2. Open a Pull Request on the original `k8s-operatorhub/community-operators` repository.
3. The OperatorHub review team will run automated CI pipelines and manually verify the manifests. 
4. Once merged, your operator will appear dynamically on **OperatorHub.io** within a few hours for the world to deploy!

---

**Note:** For internal corporate environments, you use a similar approach by building a custom `Index Image` with `opm index add` instead of submitting it to the Github community, and launching that Index inside your corporate cluster as a custom generic `CatalogSource`.
