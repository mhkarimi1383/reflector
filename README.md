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
    - apiVersion: v1
      kind: ConfigMap
      metadata:
        name: test-config
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

### Cert-Manager

You can change your `Certificate` Custom Resource to set required values, For example:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-tls
  namespace: default
spec:
  secretTemplate:
    labels:
      dev.karimi.k8s/reflect: "true"
    annotations:
      dev.karimi.k8s/reflect-namespaces: ns1,ns2
  dnsNames:
    - example.karimi.dev
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: http-issuer
  secretName: example-tls
  usages:
  - digital signature
  - key encipherment
```

`secretTemplate` is the key part of the magic

> Like Reflect CRD namespaces should exist and also if not you will get an error like that

## TODO

- [x] Support for watching created resources to block changes in them
- [x] HelmChart and deploy guid
- [ ] Support for removal in namespace list (both in crd and secret Label/Annotations)
