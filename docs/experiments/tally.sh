#!/usr/bin/env bash
# tally.sh — sum token usage across implement-issue stage logs (Arm A capture).
#
# Usage:
#   bash docs/experiments/tally.sh [STAGES_DIR]
#
# STAGES_DIR defaults to the issue-13 baseline run. Pass another run's
# logs/implement-issue/<run>/stages directory to tally a different run.
#
# Reports weighted tokens (input+cache_write+output — the cap-impact proxy),
# raw tokens (incl. cache-read), and total turns per the A/B experiment
# (see ab-pipeline-vs-epic-task-loop.md §4/§5.6).
set -euo pipefail
LD="${1:-/Users/russellgrocott/Projects/claude-pipeline/logs/implement-issue/issue-13-20260703-171225/stages}"
python3 - "$LD" <<'PY'
import sys,glob,re,os
ld=sys.argv[1]
tot={'in':0,'cw':0,'cr':0,'out':0,'turns':0}
rows=[]
for f in sorted(glob.glob(os.path.join(ld,'*.log'))):
    s=open(f,encoding='utf-8',errors='replace').read()
    def summ(k): return sum(int(x) for x in re.findall(r'"%s":(\d+)'%k,s))
    turns=re.findall(r'"num_turns":(\d+)',s); turns=int(turns[-1]) if turns else 0
    it,cw,cr,ot=summ('input_tokens'),summ('cache_creation_input_tokens'),summ('cache_read_input_tokens'),summ('output_tokens')
    rows.append((os.path.basename(f),turns,it,cw,cr,ot))
    for k,v in (('in',it),('cw',cw),('cr',cr),('out',ot),('turns',turns)): tot[k]+=v
def h(n): return f"{n/1000:.1f}k" if n<1e6 else f"{n/1e6:.2f}M"
print(f"{'stage':<28}{'turns':>6}{'in':>9}{'cw':>9}{'cache_rd':>10}{'out':>8}")
for r in rows: print(f"{r[0]:<28}{r[1]:>6}{h(r[2]):>9}{h(r[3]):>9}{h(r[4]):>10}{h(r[5]):>8}")
raw=tot['in']+tot['cw']+tot['cr']+tot['out']; weighted=tot['in']+tot['cw']+tot['out']
print('-'*70)
print(f"{'TOTAL':<28}{tot['turns']:>6}{h(tot['in']):>9}{h(tot['cw']):>9}{h(tot['cr']):>10}{h(tot['out']):>8}")
print(f"\nWEIGHTED (in+cw+out, cap proxy): {h(weighted)}  ({weighted:,})")
print(f"RAW (incl cache-read):           {h(raw)}  ({raw:,})")
print(f"TURNS: {tot['turns']}  |  STAGES: {len(rows)}")
PY