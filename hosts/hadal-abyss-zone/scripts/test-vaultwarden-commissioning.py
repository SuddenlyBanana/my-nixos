#!/usr/bin/env python3
"""Render-only GitOps checks. Needs kustomize and Python with PyYAML; no cluster API.

HADAL_GITOPS_ROOT can select a checkout; KUSTOMIZE can select the executable.
EXPECT_VAULTWARDEN_SUSPEND=false validates explicitly enabled commissioning.
"""

import os
from pathlib import Path
import shutil
import subprocess
import unittest

import yaml


ROOT = Path(os.environ.get('HADAL_GITOPS_ROOT',
            str(Path(__file__).resolve().parents[4] / 'hadal-abyss-zone-gitops')))


def key(document):
    return (document['apiVersion'], document['kind'], document['metadata'].get('namespace'), document['metadata']['name'])


class Commissioning(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        binary = os.environ.get('KUSTOMIZE') or shutil.which('kustomize')
        if not binary:
            raise RuntimeError('kustomize is required')
        cls.bundles = {}
        for name, path in [('root', 'clusters/hadal'), ('commissioning', 'apps/vaultwarden/commissioning'),
                           ('base', 'apps/vaultwarden/base'), ('other', 'apps/hadal')]:
            rendered = subprocess.run([binary, 'build', str(ROOT / path)],
                                      capture_output=True, text=True, timeout=30, check=True)
            cls.bundles[name] = list(yaml.safe_load_all(rendered.stdout))

    def find(self, bundle, kind, name):
        matches = [d for d in self.bundles[bundle] if d['kind'] == kind and d['metadata']['name'] == name]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def test_single_owner_and_other_apps_still_suspended(self):
        roots = {d['metadata']['name']: d['spec'] for d in self.bundles['root']}
        self.assertEqual(set(roots), {'apps', 'infrastructure', 'vaultwarden'})
        self.assertTrue(roots['apps']['suspend'])
        expected = os.environ.get('EXPECT_VAULTWARDEN_SUSPEND', 'true')
        self.assertIn(expected, ('true', 'false'))
        self.assertIs(roots['vaultwarden']['suspend'], expected == 'true')
        self.assertEqual(roots['vaultwarden']['path'], './apps/vaultwarden/commissioning')
        self.assertEqual(roots['vaultwarden']['dependsOn'], [{'name': 'infrastructure'}])
        self.assertEqual(roots['vaultwarden']['sourceRef'], {'kind': 'GitRepository', 'name': 'flux-system'})
        self.assertEqual(roots['vaultwarden']['postBuild']['substituteFrom'],
                         [{'kind': 'ConfigMap', 'name': 'hadal-runtime', 'optional': False}])
        ours = {key(d) for d in self.bundles['commissioning']}
        others = {key(d) for d in self.bundles['other']}
        self.assertTrue(others)
        self.assertFalse(ours & others)
        self.assertFalse(any(d['metadata'].get('namespace') == 'vaultwarden' for d in self.bundles['other']))

    def test_commissioning_has_no_public_ingress_or_ports(self):
        self.assertFalse(any(d['kind'] == 'Ingress' for d in self.bundles['commissioning']))
        services = [d for d in self.bundles['commissioning'] if d['kind'] == 'Service']
        self.assertTrue(services)
        for service in services:
            self.assertEqual(service['spec']['type'], 'ClusterIP')
            self.assertFalse(service['spec'].get('externalIPs'))
            self.assertFalse(any('nodePort' in p for p in service['spec']['ports']))
        pod = self.find('commissioning', 'Deployment', 'vaultwarden')['spec']['template']['spec']
        self.assertFalse(pod.get('hostNetwork', False))
        self.assertFalse(any(p.get('hostPort') for c in pod['containers'] for p in c.get('ports', [])))

    def test_background_jobs_and_credential_restart_paused(self):
        deployment = self.find('commissioning', 'Deployment', 'vaultwarden')
        container = deployment['spec']['template']['spec']['containers'][0]
        env = {e['name']: e.get('value') for e in container['env']}
        self.assertEqual(env['JOB_POLL_INTERVAL_MS'], '0')
        self.assertEqual(env['INVITATIONS_ALLOWED'], 'false')
        self.assertEqual(env['SIGNUPS_ALLOWED'], 'false')
        self.assertTrue(self.find('commissioning', 'CronJob', 'vaultwarden-credential-restart')['spec']['suspend'])

    def test_target_ownership_image_and_storage_preserved(self):
        deployment = self.find('commissioning', 'Deployment', 'vaultwarden')
        pod = deployment['spec']['template']['spec']
        self.assertEqual(deployment['spec']['replicas'], 1)
        self.assertEqual(pod['containers'][0]['image'], 'ghcr.io/dani-garcia/vaultwarden:1.37.3')
        self.assertEqual(pod['securityContext']['runAsUser'], 1000)
        self.assertEqual(pod['securityContext']['runAsGroup'], 1000)
        self.assertEqual(pod['securityContext']['fsGroup'], 1000)
        pv = self.find('commissioning', 'PersistentVolume', 'vaultwarden-data')
        self.assertEqual(pv['spec']['local']['path'], '/var/lib/hadal-pv/vaultwarden')
        self.assertEqual(pv['spec']['persistentVolumeReclaimPolicy'], 'Retain')
        self.assertEqual(pv['spec']['nodeAffinity']['required']['nodeSelectorTerms'][0]['matchExpressions'][0]['values'],
                         ['hadal-rke2-1'])

    def test_correct_rke2_traefik_ingress_selector(self):
        for bundle in ('commissioning', 'base'):
            policy = self.find(bundle, 'NetworkPolicy', 'vaultwarden')
            peer = policy['spec']['ingress'][0]['from'][0]
            self.assertEqual(peer['podSelector']['matchLabels']['app.kubernetes.io/name'], 'rke2-traefik')
            self.assertEqual(peer['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'], 'kube-system')
            self.assertEqual(policy['spec']['ingress'][0]['ports'], [{'port': 8080, 'protocol': 'TCP'}])
            deny = self.find(bundle, 'NetworkPolicy', 'default-deny')
            self.assertEqual(set(deny['spec']['policyTypes']), {'Ingress', 'Egress'})

    def test_database_credentials_and_verified_tls_preserved(self):
        container = self.find('commissioning', 'Deployment', 'vaultwarden')['spec']['template']['spec']['containers'][0]
        env = {e['name']: e for e in container['env']}
        for field, value in [('DB_USERNAME', 'username'), ('DB_PASSWORD', 'password')]:
            self.assertEqual(env[field]['valueFrom']['secretKeyRef'], {'name': 'vaultwarden-database', 'key': value})
        self.assertIn('sslmode=verify-full', env['DATABASE_URL']['value'])
        self.assertIn('sslrootcert=/etc/postgresql-ca/ca.crt', env['DATABASE_URL']['value'])
        names = [e['name'] for e in container['env']]
        self.assertLess(names.index('DB_USERNAME'), names.index('DATABASE_URL'))
        self.assertLess(names.index('DB_PASSWORD'), names.index('DATABASE_URL'))
        spc = self.find('commissioning', 'SecretProviderClass', 'vaultwarden')
        objects = yaml.safe_load(spc['spec']['parameters']['objects'])
        paths = {o['secretPath'] for o in objects if o['objectName'] in ('database-username', 'database-password')}
        self.assertEqual(paths, {'database/creds/vaultwarden'})
        self.assertEqual(spc['spec']['parameters']['audience'], 'openbao')

    def test_normal_base_retains_post_commissioning_features(self):
        self.find('base', 'Ingress', 'vaultwarden')
        cron = self.find('base', 'CronJob', 'vaultwarden-credential-restart')
        self.assertFalse(cron['spec'].get('suspend', False))
        env = {e['name']: e.get('value') for e in
               self.find('base', 'Deployment', 'vaultwarden')['spec']['template']['spec']['containers'][0]['env']}
        self.assertNotIn('JOB_POLL_INTERVAL_MS', env)
        self.assertEqual(env['INVITATIONS_ALLOWED'], 'true')

    def test_no_duplicate_rendered_resource_identity(self):
        for name, documents in self.bundles.items():
            with self.subTest(bundle=name):
                self.assertEqual(len(documents), len({key(d) for d in documents}))


if __name__ == '__main__':
    unittest.main()
