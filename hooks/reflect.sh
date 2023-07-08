#!/usr/bin/env bash

function sendEvent() {
	case $6 in
		Reflect)
			kubectl apply -f - <<EOF
apiVersion: v1
eventTime: $(date -u +"%Y-%m-%dT%H:%M:%S.000000Z")
firstTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
lastTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
involvedObject:
  kind: Reflect
  apiVersion: k8s.karimi.dev/v1
  name: $1
  namespace: $2
kind: Event
message: $5
metadata:
  name: reflect-$(shuf -n 8 -e {A..Z} {a..z} {0..9} | tr -d '\n')
  namespace: $2
type: $3
reportingComponent: hook-runner
reportingInstance: reflect-operator
reason: $4
action: $4
EOF
			;;
		Secret)
			kubectl apply -f - <<EOF
apiVersion: v1
eventTime: $(date -u +"%Y-%m-%dT%H:%M:%S.000000Z")
firstTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
lastTimestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
involvedObject:
  kind: Secret
  apiVersion: v1
  name: $1
  namespace: $2
kind: Event
message: $5
metadata:
  name: reflect-$(shuf -n 8 -e {A..Z} {a..z} {0..9} | tr -d '\n')
  namespace: $2
type: $3
reportingComponent: hook-runner
reportingInstance: reflect-operator
reason: $4
action: $4
EOF
			;;
		*)
			echo "Unknown kind $6"
			;;
	esac
}

function cleanupK8sResource() {
	echo $1 | jq -r 'del(.metadata.labels."dev.karimi.k8s/reflect", .metadata.annotations."dev.karimi.k8s/reflect-namespaces", .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields)'
}

function k8sCreateOrReplace() {
	echo $1 | kubectl replace -f- || echo $1 | kubectl apply -f-
}

function validateNamespaceExistance() {
	if kubectl get namespace -o name | grep -E "^namespace/$1\$" - >> /dev/null; then
		echo "1"
	else
		echo "0"
	fi
}

ARRAY_COUNT=$(jq -r '. | length-1' $BINDING_CONTEXT_PATH)

if [[ $1 == "--config" ]] ; then
	cat <<EOF
{
  "configVersion":"v1",
  "kubernetesValidating": [
    {
      "name": "reflect-validator.k8s.karimi.dev",
      "rules": [
      	{
          "apiVersions": ["v1"],
	  "apiGroups": ["k8s.karimi.dev"],
      	  "resources": ["reflects"],
      	  "operations": ["CREATE", "UPDATE"],
	  "scope": "Namespaced"
        },
      ],
      "failurePolicy": "Fail"
    },
    {
      "name": "reflected-secret-validator.k8s.karimi.dev",
      "labelSelector": {
        "matchLabels": {
	  "dev.karimi.k8s/reflect": "true"
        }
      },
      "rules": [
        {
	  "operations": ["CREATE", "UPDATE"],
	  "apiVersions": ["v1"],
	  "apiGroups": [""],
	  "resources": ["secrets"],
	  "scope": "Namespaced"
	}
      ],
      "failurePolicy": "Fail"
    }
  ],
  "kubernetes": [
    {
      "name": "ReflectObject",
      "apiVersion": "k8s.karimi.dev/v1",
      "kind": "Reflect",
      "executeHookOnEvent":["Added", "Modified", "Deleted"]
    },
    {
      "name": "SecretWatcher",
      "apiVersion": "v1",
      "kind": "Secret",
      "executeHookOnEvent": [ "Added", "Modified", "Deleted" ],
      "labelSelector": {
        "matchLabels": {
          "dev.karimi.k8s/reflect": "true"
        }
      }
    }
  ]
}
EOF
else
	type=$(jq -r '.[0].type' $BINDING_CONTEXT_PATH)
	case $type in
		Synchronization)
			echo "Got Synchronization event"
			;;

		Validating)
			for IND in $(seq 0 $ARRAY_COUNT)
			do
				kind=$(jq -r ".[$IND].review.request.object.kind" $BINDING_CONTEXT_PATH)
				case $kind in
					Reflect)
						namespaceCount=$(jq -r ".[$IND].review.request.object.spec.namespaces | length-1" $BINDING_CONTEXT_PATH)
						notFound=""
						isValid="1"
						for CURNS in $(seq 0 $namespaceCount)
						do
							namespace=$(jq -r ".[$IND].review.request.object.spec.namespaces[$CURNS]" $BINDING_CONTEXT_PATH)
							if [[ $(validateNamespaceExistance $namespace) == "1" ]] >> /dev/null; then
								echo "Found namespace $namespace"
							else
                                        			echo "Missing namespace $namespace"
								notFound="$namespace $notFound"
								isValid="0"
							fi
						done
						if [[ $isValid == "1" ]]; then
							cat <<EOF > $VALIDATING_RESPONSE_PATH
{"allowed": true}
EOF
						else
							notFound="${notFound%?}"
							cat <<EOF > $VALIDATING_RESPONSE_PATH
{"allowed": false, "message": "Namespaces ($notFound) does not exist. all of the namespaces should exist before creating new Reflect"}
EOF
						fi
						;;

					Secret)
						namespaceList=$(jq -r ".[$IND].review.request.object.metadata.annotations.\"dev.karimi.k8s/reflect-namespaces\"" $BINDING_CONTEXT_PATH)
						namespaceArray=(${namespaceList//,/ })
						notFound=""
						isValid="1"
						for namespace in ${namespaceArray[@]}
						do
							if [[ $(validateNamespaceExistance $namespace) == "1" ]] >> /dev/null; then
								echo "Found namespace $namespace"
							else
								echo "Missing namespace $namespace"
								notFound="$namespace $notFound"
								isValid="0"
							fi
						done
						if [[ $isValid == "1" ]]; then
							cat <<EOF > $VALIDATING_RESPONSE_PATH
{"allowed": true}
EOF
						else
							notFound="${notFound%?}"
							cat <<EOF > $VALIDATING_RESPONSE_PATH
{"allowed": false, "message": "Namespaces ($notFound) does not exist. all of the namespaces should exist before creating new Reflected Secret"}
EOF
						fi
						;;
					*)
						echo "Unknown kind $kind"
						;;
				esac
			done
			;;

		Event)
			for IND in $(seq 0 $ARRAY_COUNT)
			do
				resourceEvent=$(jq -r ".[$IND].watchEvent" $BINDING_CONTEXT_PATH)
				resourceName=$(jq -r ".[$IND].object.metadata.name" $BINDING_CONTEXT_PATH)
				resourceNamespace=$(jq -r ".[$IND].object.metadata.namespace" $BINDING_CONTEXT_PATH)
				resourceKind=$(jq -r ".[$IND].object.kind" $BINDING_CONTEXT_PATH)
				case $resourceKind in
					Reflect)
						reflectDestinationCount=$(jq -r ".[$IND].object.spec.namespaces | length-1" $BINDING_CONTEXT_PATH)
						reflectItemCount=$(jq -r ".[$IND].object.spec.items | length-1" $BINDING_CONTEXT_PATH)
						case $resourceEvent in
							Added)
								sendEvent "$resourceName" "$resourceNamespace" Normal "Creating" "Working on creation..." $resourceKind
								for CURNS in $(seq 0 $reflectDestinationCount)
								do
									namespace=$(jq -r ".[$IND].object.spec.namespaces[$CURNS]" $BINDING_CONTEXT_PATH)
									sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on creation of resources in namespace $namespace..." $resourceKind
									for CURI in $(seq 0 $reflectItemCount)
									do
										resource=$(jq -r ".[$IND].object.spec.items[$CURI] | .metadata.namespace = \"$namespace\" | tostring" $BINDING_CONTEXT_PATH)
										k8sCreateOrReplace $resource
									done
									sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." $resourceKind
								done
								sendEvent "$resourceName" "$resourceNamespace" Normal "Created" "created resources." $resourceKind
								;;

							Modified)
								sendEvent "$resourceName" "$resourceNamespace" Normal "Updating" "Working on updates..." $resourceKind
								for CURNS in $(seq 0 $reflectDestinationCount)
								do
									namespace=$(jq -r ".[$IND].object.spec.namespaces[$CURNS]" $BINDING_CONTEXT_PATH)
									sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on update of resources in namespace $namespace..." $resourceKind
									for CURI in $(seq 0 $reflectItemCount)
									do
										resource=$(jq -r ".[$IND].object.spec.items[$CURI] | .metadata.namespace = \"$namespace\" | tostring" $BINDING_CONTEXT_PATH)
										k8sCreateOrReplace "$resource"
									done
									sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." $resourceKind
								done
								sendEvent "$resourceName" "$resourceNamespace" Normal "Updated" "created/updated resources." $resourceKind
								;;

							Deleted)
								sendEvent "$resourceName" "$resourceNamespace" Normal "Removing" "Working on removal..." $resourceKind
								for CURNS in $(seq 0 $reflectDestinationCount)
								do
									namespace=$(jq -r ".[$IND].object.spec.namespaces[$CURNS]" $BINDING_CONTEXT_PATH)
									sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on removal of resources in namespace $namespace..." $resourceKind
									for CURI in $(seq 0 $reflectItemCount)
									do
										resource=$(jq -r ".[$IND].object.spec.items[$CURI] | .metadata.namespace = \"$namespace\" | tostring" $BINDING_CONTEXT_PATH)
										echo "$resource" | kubectl delete -f-
									done
									sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." $resourceKind
								done
								sendEvent "$resourceName" "$resourceNamespace" Normal "Removed" "removed resources." $resourceKind
								;;

							*)
								echo "Unknown operation $resourceEvent on $resourceName in namespace $resourceNamespace"
								;;
						esac
						;;
					Secret)
						namespaceList=$(jq -r ".[$IND].object.metadata.annotations.\"dev.karimi.k8s/reflect-namespaces\"" $BINDING_CONTEXT_PATH)
						namespaceArray=(${namespaceList//,/ })
						case $resourceEvent in
							Added)
								sendEvent "$resourceName" "$resourceNamespace" Normal "Creating" "Working on creation..." $resourceKind
								for namespace in ${namespaceArray[@]}
								do
									sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on creation of Secret in namespace $namespace..." $resourceKind
									resource=$(jq -r ".[$IND].object | .metadata.namespace = \"$namespace\" | tostring" $BINDING_CONTEXT_PATH)
									resource=$(cleanupK8sResource $resource | jq -r 'tostring')
									k8sCreateOrReplace $resource
								        sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." $resourceKind
								done
								sendEvent "$resourceName" "$resourceNamespace" Normal "Created" "created secrets." $resourceKind
								;;
                            				Modified)
                                				sendEvent "$resourceName" "$resourceNamespace" Normal "Updating" "Working on updates..." $resourceKind
                                				for namespace in ${namespaceArray[@]}
                                				do
                                    					sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on create/update of Secret in namespace $namespace..." $resourceKind
                                    					resource=$(jq -r ".[$IND].object | .metadata.namespace = \"$namespace\" | tostring" $BINDING_CONTEXT_PATH)
									resource=$(cleanupK8sResource $resource | jq -r 'tostring')
                                    					k8sCreateOrReplace $resource
                                        				sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." $resourceKind
                                				done
                                				sendEvent "$resourceName" "$resourceNamespace" Normal "Updated" "created/updated secrets." $resourceKind
                                				;;
							Deleted)
                                				sendEvent "$resourceName" "$resourceNamespace" Normal "Removing" "Working on removal..." $resourceKind
                                				for namespace in ${namespaceArray[@]}
                                				do
                                    					sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceStarted" "Working on removal of Secret in namespace $namespace..." $resourceKind
                                    					resource=$(jq -r ".[$IND].object | .metadata.namespace = \"$namespace\" | tostring" $BINDING_CONTEXT_PATH)
                                    					resource=$(cleanupK8sResource $resource | jq -r 'tostring')
                                    					echo $resource | kubectl delete -f-
                                        				sendEvent "$resourceName" "$resourceNamespace" Normal "NamespaceFinished" "Done with namespace $namespace." $resourceKind
                                				done
                                				sendEvent "$resourceName" "$resourceNamespace" Normal "Removed" "removed secrets." $resourceKind
								;;
							*)
								echo "Unknown Operation $resourceEvent"
								;;
						esac
						;;
					*)
						echo "Unknown kind $kind"
					esac
			done
			;;

		*)
			echo "Unknown type $type"
			;;
	esac
fi

