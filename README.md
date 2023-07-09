# Reflector

 A generic K8s reflector that handles every kind, with support for automatically created secrets


## Installation

To install reflector run the following command:

```bash
helm install reflector reflector -n reflector --repo https://reflector.karimi.dev --create-namespace
```

Also [here](./charts/reflector/values.yaml) you can find default helm values if you prefer to customize them.

## Using Reflect CRD

Here is an example of using `Reflect` CRD to Reflect your resources

```yaml
---
apiVersion: "k8s.karimi.dev/v1"
kind: Reflect
metadata:
  name: test
spec:
  namespaces:
    - ns1
    - ns2
  items:
    - metadata:
        name: test-config
      apiVersion: v1
      kind: ConfigMap
      data:
        foo: bar
```

> Every namespace in namespaces list should exist before creation, you will get validation error if operator can't find one or more namespaces. Here is an error example 'error: reflects.k8s.karimi.dev "test" could not be patched: admission webhook "reflect-validator.k8s.karimi.dev" denied the request: Namespaces (not-found-ns2 not-found-ns1) does not exist. all of the namespaces should exist before creating new Reflect'


## Using Label/Annotations for Secrets

This is mostly used for automatically created secrets (e.g. `cert-manager`)

if a secret contains following properties it will get reflected

```yaml
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: example.com-tls
  labels:
    dev.karimi.k8s/reflect: "true" # important
  annotations:
    dev.karimi.k8s/reflect-namespaces: ns1,ns2 # important
data:
  ...
```

> Like Reflect CRD namespaces should exist and also if not you will get an error like that


## TODO

- [ ] Support for watcing created resources to block changes in them
- [x] HelmChart and deploy guid

