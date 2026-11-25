#!/usr/bin/env python3
"""Add subscribers IMSI ...0005..N to $LAB/cn5g/database/oai_db.sql by cloning the
IMSI ...0004 rows (same K/OPc, slice-1 static IP 10.0.0.<i+1>). Idempotent.
usage: extend_db_ues.py <oai_db.sql> <max_ue>"""
import re, sys
path, n = sys.argv[1], int(sys.argv[2])
s = open(path).read()
def stmt(table):  # the INSERT statement of this table that contains UE 4
    m = re.search(r"INSERT INTO `%s` .*?;\n" % table, s, re.S)
    blocks = [b for b in re.findall(r"INSERT INTO `%s` .*?;\n" % table, s, re.S) if "001010000000004" in b]
    assert len(blocks) == 1, table
    return blocks[0]
for table in ("AuthenticationSubscription", "SessionManagementSubscriptionData"):
    b = stmt(table)
    add = ""
    for i in range(5, n + 1):
        imsi = "0010100000000%02d" % i
        if re.search(r"INSERT INTO `%s` [^;]*%s" % (table, imsi), s): continue
        c = b.replace("001010000000004", imsi)
        c = c.replace('10.0.0.5', '10.0.0.%d' % (i + 1))
        add += c
    s = s.replace(b, b + add)
open(path, "w").write(s)
