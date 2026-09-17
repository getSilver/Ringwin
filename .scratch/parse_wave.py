import json
text = open('.scratch/wave-output.txt', encoding='utf-8', errors='replace').read()
i = text.find('projection never satisfied')
seg = text[i:i+6000]
print('views in snapshot:', seg.count('target_identity'))
for m in json.JSONDecoder().raw_decode(seg[seg.find('['):seg.find(']')+1]):
    print(m.get('target_identity'), m.get('mode'), m.get('effective_authority'), m.get('unresolved_latches'))
