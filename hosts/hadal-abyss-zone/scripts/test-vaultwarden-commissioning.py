#!/usr/bin/env python3
"""Render-only GitOps checks. Needs kustomize and Python with PyYAML; no cluster API.

HADAL_GITOPS_ROOT can select a checkout; KUSTOMIZE can select the executable.
Defaults validate the enabled public cutover. EXPECT_VAULTWARDEN_MODE can select
commissioning; EXPECT_VAULTWARDEN_SUSPEND can validate a paused child.
"""

import copy
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

    def test_single_owner_and_expected_application_rollout_state(self):
        roots = {d['metadata']['name']: d['spec'] for d in self.bundles['root']}
        self.assertEqual(set(roots), {'apps', 'infrastructure', 'vaultwarden'})
        expected_apps = os.environ.get('EXPECT_APPS_SUSPEND', 'false')
        self.assertIn(expected_apps, ('true', 'false'))
        self.assertIs(roots['apps']['suspend'], expected_apps == 'true')
        expected = os.environ.get('EXPECT_VAULTWARDEN_SUSPEND', 'false')
        self.assertIn(expected, ('true', 'false'))
        self.assertIs(roots['vaultwarden']['suspend'], expected == 'true')
        mode = os.environ.get('EXPECT_VAULTWARDEN_MODE', 'base')
        self.assertIn(mode, ('base', 'commissioning'))
        self.assertEqual(roots['vaultwarden']['path'], f'./apps/vaultwarden/{mode}')
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

    def test_application_background_jobs_still_paused(self):
        deployment = self.find('commissioning', 'Deployment', 'vaultwarden')
        container = deployment['spec']['template']['spec']['containers'][0]
        env = {e['name']: e.get('value') for e in container['env']}
        self.assertEqual(env['JOB_POLL_INTERVAL_MS'], '0')
        self.assertEqual(env['INVITATIONS_ALLOWED'], 'false')
        self.assertEqual(env['SIGNUPS_ALLOWED'], 'false')

    def test_credential_maintenance_enabled_without_other_job_changes(self):
        cron = self.find('commissioning', 'CronJob', 'vaultwarden-credential-restart')
        expected = copy.deepcopy(self.find('base', 'CronJob', 'vaultwarden-credential-restart'))
        expected['spec']['suspend'] = False
        self.assertEqual(cron, expected)
        self.assertIs(cron['spec']['suspend'], False)
        self.assertEqual(cron['spec']['schedule'], '23 */12 * * *')
        self.assertEqual(cron['spec']['timeZone'], 'Etc/UTC')
        self.assertEqual(cron['spec']['concurrencyPolicy'], 'Forbid')
        pod = cron['spec']['jobTemplate']['spec']['template']['spec']
        self.assertEqual(pod['serviceAccountName'], 'vaultwarden-credential-restart')
        self.assertEqual(len(pod['containers']), 1)
        self.assertEqual(pod['containers'][0]['args'],
                         ['rollout', 'restart', 'deployment/vaultwarden', '--namespace=vaultwarden'])

    def test_credential_restart_permissions_stay_narrow(self):
        role = self.find('commissioning', 'Role', 'vaultwarden-credential-restart')
        self.assertEqual(role['metadata']['namespace'], 'vaultwarden')
        self.assertEqual(role['rules'], [{
            'apiGroups': ['apps'], 'resources': ['deployments'],
            'resourceNames': ['vaultwarden'], 'verbs': ['get', 'patch'],
        }])
        binding = self.find('commissioning', 'RoleBinding', 'vaultwarden-credential-restart')
        self.assertEqual(binding['metadata']['namespace'], 'vaultwarden')
        self.assertEqual(binding['subjects'], [{
            'kind': 'ServiceAccount', 'name': 'vaultwarden-credential-restart',
            'namespace': 'vaultwarden',
        }])
        self.assertEqual(binding['roleRef'], {
            'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'Role',
            'name': 'vaultwarden-credential-restart',
        })
        policy = self.find('commissioning', 'CiliumNetworkPolicy', 'credential-restart')
        self.assertEqual(policy['spec']['endpointSelector']['matchLabels'],
                         {'app.kubernetes.io/name': 'vaultwarden-credential-restart'})
        self.assertEqual(policy['spec']['egress'], [{
            'toEntities': ['kube-apiserver'],
            'toPorts': [{'ports': [{'protocol': 'TCP', 'port': '6443'},
                                  {'protocol': 'TCP', 'port': '443'}]}],
        }])

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

    def test_remaining_apps_accept_the_actual_rke2_traefik_pods(self):
        for name, port in [('www-femboy-exposed', 80), ('wapmail', 8080)]:
            with self.subTest(app=name):
                policy = self.find('other', 'NetworkPolicy', name)
                self.assertEqual(policy['metadata']['namespace'], name)
                self.assertEqual(policy['spec']['ingress'], [{
                    'from': [{
                        'namespaceSelector': {'matchLabels': {
                            'kubernetes.io/metadata.name': 'kube-system',
                        }},
                        'podSelector': {'matchLabels': {
                            'app.kubernetes.io/name': 'rke2-traefik',
                        }},
                    }],
                    'ports': [{'protocol': 'TCP', 'port': port}],
                }])

    def test_remaining_apps_use_registered_sops_pull_secrets(self):
        apps = self.find('root', 'Kustomization', 'apps')
        self.assertEqual(apps['spec']['decryption'], {
            'provider': 'sops', 'secretRef': {'name': 'sops-age'},
        })
        recipients = []
        for namespace, name in [('www-femboy-exposed', 'ghcr-www-femboy-exposed'),
                                ('wapmail', 'ghcr-wapmail')]:
            secret = self.find('other', 'Secret', name)
            self.assertEqual(secret['metadata']['namespace'], namespace)
            self.assertEqual(secret['type'], 'kubernetes.io/dockerconfigjson')
            self.assertEqual(set(secret['data']), {'.dockerconfigjson'})
            self.assertTrue(secret['data']['.dockerconfigjson'].startswith('ENC[AES256_GCM,'))
            self.assertNotIn('stringData', secret)
            self.assertEqual(secret['sops']['encrypted_regex'], '^(data|stringData)$')
            recipients.append({key['recipient'] for key in secret['sops']['age']})
            account = self.find('other', 'ServiceAccount', namespace)
            self.assertEqual(account['imagePullSecrets'], [{'name': name}])
        self.assertTrue(recipients[0])
        self.assertEqual(recipients[0], recipients[1])

    def test_remaining_app_images_resolve_to_immutable_digests(self):
        substitutions = self.find('root', 'Kustomization', 'apps')['spec']['postBuild']['substitute']
        for namespace, variable in [('www-femboy-exposed', 'WWW_FEMBOY_EXPOSED_IMAGE_DIGEST'),
                                    ('wapmail', 'WAPMAIL_IMAGE_DIGEST')]:
            digest = substitutions[variable]
            self.assertRegex(digest, r'^sha256:[0-9a-f]{64}$')
            containers = self.find('other', 'Deployment', namespace)['spec']['template']['spec']['containers']
            for container in containers:
                self.assertEqual(container['image'].count('${' + variable + '}'), 1)
                image = container['image'].replace('${' + variable + '}', digest)
                self.assertRegex(image, r'^ghcr.io/suddenlybanana/[a-z0-9.\-]+@sha256:[0-9a-f]{64}$')

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
        ingress = self.find('base', 'Ingress', 'vaultwarden')
        self.assertEqual(ingress['spec']['ingressClassName'], 'traefik')
        self.assertEqual(ingress['metadata']['annotations'],
                         {'traefik.ingress.kubernetes.io/router.entrypoints': 'web'})
        self.assertEqual(ingress['spec']['rules'], [{
            'host': '${VAULTWARDEN_HOST}',
            'http': {'paths': [{'path': '/', 'pathType': 'Prefix', 'backend': {
                'service': {'name': 'vaultwarden', 'port': {'name': 'http'}},
            }}]},
        }])
        cron = self.find('base', 'CronJob', 'vaultwarden-credential-restart')
        self.assertFalse(cron['spec'].get('suspend', False))
        env = {e['name']: e.get('value') for e in
               self.find('base', 'Deployment', 'vaultwarden')['spec']['template']['spec']['containers'][0]['env']}
        self.assertNotIn('JOB_POLL_INTERVAL_MS', env)
        self.assertEqual(env['INVITATIONS_ALLOWED'], 'true')
        self.assertEqual(env['SIGNUPS_ALLOWED'], 'false')
        self.assertEqual(env['DOMAIN'], 'https://${VAULTWARDEN_HOST}')
        names = [e['name'] for e in
                 self.find('base', 'Deployment', 'vaultwarden')['spec']['template']['spec']['containers'][0]['env']]
        self.assertLess(names.index('DB_USERNAME'), names.index('DATABASE_URL'))
        self.assertLess(names.index('DB_PASSWORD'), names.index('DATABASE_URL'))

    def test_cutover_preserves_existing_resources_and_limits_changes(self):
        base = {key(d): copy.deepcopy(d) for d in self.bundles['base']}
        commissioning = {key(d): copy.deepcopy(d) for d in self.bundles['commissioning']}
        self.assertEqual(set(base) - set(commissioning),
                         {key(self.find('base', 'Ingress', 'vaultwarden'))})
        self.assertFalse(set(commissioning) - set(base))
        for identity, document in commissioning.items():
            if document['kind'] == 'Deployment':
                container = document['spec']['template']['spec']['containers'][0]
                container['env'] = [e for e in container['env'] if e['name'] != 'JOB_POLL_INTERVAL_MS']
                for env in container['env']:
                    if env['name'] == 'INVITATIONS_ALLOWED':
                        env['value'] = 'true'
                # Strategic merge puts the patched invitation variable first.
                # Credential expansion order is checked separately in both bundles.
                base_container = base[identity]['spec']['template']['spec']['containers'][0]
                container['env'].sort(key=lambda e: e['name'])
                base_container['env'].sort(key=lambda e: e['name'])
            if document['kind'] == 'CronJob':
                self.assertIs(document['spec'].pop('suspend'), False)
            with self.subTest(resource=identity):
                self.assertEqual(document, base[identity])

    def test_no_duplicate_rendered_resource_identity(self):
        for name, documents in self.bundles.items():
            with self.subTest(bundle=name):
                self.assertEqual(len(documents), len({key(d) for d in documents}))


if __name__ == '__main__':
    unittest.main()
