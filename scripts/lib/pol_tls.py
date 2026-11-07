"""pol_tls — the python side of lib/tls.sh: ONE TLS policy for every urllib call the CLI makes.

    from pol_tls import tls_context, tls_mode
    urllib.request.urlopen(req, context=tls_context())

Reads the same two names as the shell: POL_TLS_CA=<pem> -> a verifying context trusting that file (wins when both
are set, and says that the bypass was ignored); POL_TLS_INSECURE=1 -> an unverified context plus the same [WARN]
on stderr; neither -> None (the system trust store). POLARI_INSECURE=1 is the alias of the old name; a script's
--insecure flag sets POL_TLS_INSECURE=1 before importing. This is the only place the CLI may build an unverified
context (tls-selftest.sh audits the tree)."""
import os
import ssl
import sys

_TRUE = ('1', 'true', 'yes', 'on')
_said = set()


def _say(msg):
    if msg not in _said:
        _said.add(msg)
        print(msg, file=sys.stderr, flush=True)


def tls_mode():
    if os.environ.get('POLARI_INSECURE', '') in _TRUE and os.environ.get('POL_TLS_INSECURE', '') == '':
        os.environ['POL_TLS_INSECURE'] = '1'
    if os.environ.get('POL_TLS_CA'):
        return 'cacert'
    if os.environ.get('POL_TLS_INSECURE', '') in _TRUE:
        return 'insecure'
    return 'verified'


def tls_context(url=''):
    mode = tls_mode()
    if mode == 'cacert':
        ca = os.environ['POL_TLS_CA']
        if os.environ.get('POL_TLS_INSECURE', '') in _TRUE:
            _say('[WARN] POL_TLS_INSECURE ignored: POL_TLS_CA=%s is set and verification against it wins' % ca)
        if not os.path.isfile(ca):
            sys.exit('[FAIL] POL_TLS_CA=%s is not a readable PEM file' % ca)
        return ssl.create_default_context(cafile=ca)
    if mode == 'insecure':
        _say('[WARN] TLS verification OFF (POL_TLS_INSECURE=1): %s' % (url or 'urllib'))
        return ssl._create_unverified_context()
    return None
