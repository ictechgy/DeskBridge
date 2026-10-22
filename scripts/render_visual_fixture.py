#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Render only new synthetic native views. Never launch production App.main or read user settings."""
from pathlib import Path
import argparse,json,plistlib,subprocess,tempfile

ROOT=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--interactive',choices=['desktop','files','setup','first-run','certificate-error','compact','files-compact','dark'])
args=parser.parse_args()
output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
lib=ROOT/'build/release/lib'
if not (lib/'libGlimmerEngine.a').exists():raise SystemExit('Build release modules first.')
with tempfile.TemporaryDirectory(prefix='deskbridge-ui-') as name:
    fixture=Path(name)
    extension=fixture/'SyntheticEntry.swift'
    extension.write_text('import Foundation\nextension SFTPEntry { public static func visualFixture(name: String, size: UInt64) -> SFTPEntry { SFTPEntry(name: name, path: "/files/Projects/" + name, kind: .file, size: size) } }\n')
    common=['-swift-version','6','-target','arm64-apple-macosx26.0','-sdk',sdk,'-O','-module-cache-path',str(fixture/'module-cache')]
    records=[]
    def run(label,argv):
        result=subprocess.run(argv,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        (output/(label+'.stdout')).write_bytes(result.stdout)
        (output/(label+'.stderr')).write_bytes(result.stderr)
        records.append({'label':label,'argv':argv,'exitCode':result.returncode})
        (output/'invocations.json').write_text(json.dumps(records,indent=2)+'\n')
        if result.returncode:raise SystemExit(result.stderr.decode(errors='replace'))
        print(label+': passed',flush=True)
    run('compile-fixture-core',['/usr/bin/swiftc','-parse-as-library','-emit-library','-static','-emit-module','-module-name','DeskBridgeCore',*common,*map(str,sorted((ROOT/'Sources/DeskBridgeCore').glob('*.swift'))),str(extension),'-emit-module-path',str(fixture/'DeskBridgeCore.swiftmodule'),'-o',str(fixture/'libDeskBridgeCore.a')])
    sources=[p for p in sorted((ROOT/'Sources/DeskBridgeApp').rglob('*.swift')) if p.name!='DeskBridgeApp.swift']
    bundle=fixture/'DeskBridgePreview.app'
    executable=bundle/'Contents/MacOS/DeskBridgeVisualFixture'
    executable.parent.mkdir(parents=True)
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'DeskBridgeVisualFixture','CFBundleIdentifier':'org.deskbridge.visualfixture','CFBundleName':'DeskBridgePreview','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True}))
    run('compile-native-fixture',['/usr/bin/swiftc','-parse-as-library','-module-name','DeskBridgeVisualFixture',*common,'-I',str(fixture),'-I',str(lib),str(fixture/'libDeskBridgeCore.a'),str(lib/'libGlimmerEngine.a'),*map(str,sources),str(ROOT/'scripts/visual_fixture.swift'),'-o',str(executable)])
    if args.interactive:
        print('Interactive synthetic app: '+str(bundle),flush=True)
        subprocess.run([str(executable),str(fixture),str(output),'--interactive',args.interactive],check=True)
    else:
        run('render-native-fixture',[str(executable),str(fixture),str(output)])
print('Native synthetic snapshots: '+str(output))
