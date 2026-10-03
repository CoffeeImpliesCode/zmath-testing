import pathlib,subprocess,json,sys,hashlib,os
R=pathlib.Path('/tmp/tmp/zmath-perf-round.Dz4uxZhl')
ZIG='/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/zig'
rows=[]
source_identity=json.loads((R/'final-v4-source-identity.json').read_text())['tree_sha256']
build_source_sha256=hashlib.sha256((R/'consumer-smoke/build.zig').read_bytes()).hexdigest()
for target,runner,cpu in [('x86_64-linux-gnu.2.38','', 'haswell'),('aarch64_be-linux','/bin/qemu-aarch64_be','baseline'),('armeb-linux','/bin/qemu-armeb','baseline'),('mips-linux','/bin/qemu-mips','baseline'),('mipsel-linux','/bin/qemu-mipsel','baseline')]:
 for mode in ['Debug','ReleaseSafe']:
  prefix=R/'final-v4-consumers'/target/mode
  cmd=[ZIG,'build','-Dtarget='+target,'-Dcpu='+cpu,'-Doptimize='+mode,'--cache-dir',str(R/'consumer-smoke-cache'),'--prefix',str(prefix),'--summary','all']
  build=subprocess.run(cmd,cwd=R/'consumer-smoke',capture_output=True,text=True)
  exe=prefix/'bin/api-round-consumer'
  run_cmd=([runner] if runner else [])+[str(exe)]
  run=subprocess.run(run_cmd,capture_output=True,text=True) if build.returncode==0 else None
  row={'compiler_backend':'LLVM','runtime_tree_sha256':source_identity,'build_source_sha256':build_source_sha256,'target':target,'mode':mode,'build_command':cmd,'build_cwd':str(R/'consumer-smoke'),'build_exit':build.returncode,'build_output':build.stdout+build.stderr,'run_command':run_cmd,'run_exit':run.returncode if run else None,'run_output':run.stdout+run.stderr if run else None,'source_sha256':hashlib.sha256((R/'consumer-smoke/main.zig').read_bytes()).hexdigest(),'executable_sha256':hashlib.sha256(exe.read_bytes()).hexdigest() if exe.exists() else None}
  rows.append(row); print(json.dumps(row),flush=True)
  (R/'final-v4-consumer-llvm-results.json').write_text(json.dumps(rows,indent=2)+'\n')
  if build.returncode or not run or run.returncode: sys.exit(1)
print('All ten actual consumer executions passed.',flush=True)
