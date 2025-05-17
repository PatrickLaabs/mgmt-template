package main

import (
	"example.com/cdk8s-test/imports/k8s"
	"github.com/aws/constructs-go/constructs/v10"
	"github.com/aws/jsii-runtime-go"
	"github.com/cdk8s-team/cdk8s-core-go/cdk8s/v2"
)

func NewChart(scope constructs.Construct, id string, ns string, appLabel string) cdk8s.Chart {

	chart := cdk8s.NewChart(scope, jsii.String(id), &cdk8s.ChartProps{
		Namespace: jsii.String(ns),
	})

	labels := map[string]*string{
		"app": jsii.String(appLabel),
	}

	k8s.NewKubeDeployment(chart, jsii.String("deployment"), &k8s.KubeDeploymentProps{
		Spec: &k8s.DeploymentSpec{
			Replicas: jsii.Number(1),
			Selector: &k8s.LabelSelector{
				MatchLabels: &labels,
			},
			Template: &k8s.PodTemplateSpec{
				Metadata: &k8s.ObjectMeta{
					Labels: &labels,
				},
				Spec: &k8s.PodSpec{
					Containers: &[]*k8s.Container{{
						Name:  jsii.String("sample-application-cdk8s"),
						Image: jsii.String("ghcr.io/patricklaabs/sample-application:sample-application-1.0.4"),
						Ports: &[]*k8s.ContainerPort{{
							ContainerPort: jsii.Number(80),
						}},
					}},
				},
			},
		},
	})

	return chart
}

func main() {
	app := cdk8s.NewApp(nil)

	NewChart(app, "sample-app", "default", "sample-application-cdk8s")

	app.Synth()
}
