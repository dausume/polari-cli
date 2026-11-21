#!/usr/bin/env python3
"""The container image a medium's target is proven in, from the isle's record of supported operating systems.

The record is the isle CLI's apt/supported-os.json, read with the isle CLI's own reader (scripts/supported_os.py):
first the one of this checkout's forest (the medium was built from it), else the one of the installed isle CLI.
The checks of a medium keep no list of systems of their own; a target the record does not have is refused.
"""
import importlib.util
from pathlib import Path

READER = 'supported_os.py'
PLACES = (Path(__file__).resolve().parents[3] / 'Isle-Mesh' / 'isle-cli' / 'scripts',
          Path('/usr/share/isle-mesh/isle-cli/scripts'))


def systems(places=PLACES):
    """The systems of the record.  ValueError (in plain words) when no reader is found or the record is not readable."""
    for place in places:
        reader = Path(place) / READER
        if not reader.is_file(): continue
        spec = importlib.util.spec_from_file_location('isle_supported_os', reader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.load()
    raise ValueError('The record of supported operating systems was not found (looked for %s in: %s).'
                     % (READER, ', '.join(str(p) for p in places)))


def base_image(target, places=PLACES):
    """The image of a target such as ubuntu-22.04.  ValueError, naming the targets the record has, for any other."""
    found = systems(places)
    entry = next((s for s in found if s['id'] == target), None)
    if entry is None:
        raise ValueError('The medium is built for %r, which is not in the record of supported operating systems (%s).'
                         % (target, ', '.join(s['id'] for s in found)))
    return entry['baseImage']
