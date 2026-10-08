"""Assemble RESULTS.md from results/*.json and test_ports_output.txt.
Usage: python3 -I make_results.py
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir

import numpy as np

from validation_common import CLASSES, fmt

HERE = os.path.dirname(os.path.abspath(__file__))
R = os.path.join(HERE, "results")
CN = {"wake": "Wake", "core": "Core (N1+N2)", "deep": "Deep (N3/S3+S4)", "rem": "REM"}


def load(name):
    p = os.path.join(R, name)
    return json.load(open(p)) if os.path.exists(p) else None


def pct(x, nd=1):
    return "n/a" if x is None or (isinstance(x, float) and np.isnan(x)) else f"{100 * x:.{nd}f} %"


def cm_table(cm, title):
    cm = np.array(cm)
    lines = [f"**{title}** (rows = PSG reference, columns = app; counts)", "",
             "| Reference \\ App | Wake | Core | Deep | REM | Total |", "|---|---:|---:|---:|---:|---:|"]
    for i, c in enumerate(CLASSES):
        lines.append(f"| {CN[c]} | " + " | ".join(str(int(v)) for v in cm[i]) + f" | {int(cm[i].sum())} |")
    lines.append("| Total | " + " | ".join(str(int(v)) for v in cm.sum(0)) + f" | {int(cm.sum())} |")
    return "\n".join(lines)


def sleep_section(variants):
    out = []
    out.append("| Dataset / variant | Records classified | 5-min epochs | Accuracy | Cohen's κ | 30-s epochs | Accuracy | Cohen's κ | Majority-class accuracy (5-min) |")
    out.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for label, d in variants:
        if d is None:
            continue
        p = d["pooled"]
        s5, s30 = p["stats5"], p["stats30"]
        cm = np.array(p["cm5"])
        maj = cm.sum(1).max() / cm.sum()
        out.append(f"| {label} | {p['n_records_classified']}/{p['n_records_total']} | {s5['n']} | {pct(s5['accuracy'])} | {fmt(s5['kappa'], 3)} | "
                   f"{s30['n']} | {pct(s30['accuracy'])} | {fmt(s30['kappa'], 3)} | {pct(maj)} |")
    return "\n".join(out)


def class_table(variants):
    out = ["| Dataset / variant | Resolution | " + " | ".join(f"{CN[c]} sens. | {CN[c]} prec." for c in CLASSES) + " |",
           "|---|---|" + "---:|---:|" * len(CLASSES)]
    for label, d in variants:
        if d is None:
            continue
        for res in ("5", "30"):
            s = d["pooled"]["stats" + res]
            out.append(f"| {label} | {'5 min' if res == '5' else '30 s'} | " +
                       " | ".join(f"{pct(s['sens_' + c])} | {pct(s['prec_' + c])}" for c in CLASSES) + " |")
    return "\n".join(out)


def minutes_table(variants):
    out = ["| Dataset / variant | Quantity | n records | Mean PSG (min) | Mean app (min) | Bias app − PSG (min) | 95 % limits of agreement (min) |",
           "|---|---|---:|---:|---:|---:|---|"]
    for label, d in variants:
        if d is None:
            continue
        p = d["pooled"]
        for q, name in (("tst", "Total sleep time"), ("deep", "Deep minutes"), ("rem", "REM minutes")):
            b = p["ba_" + q]
            out.append(f"| {label} | {name} | {b['n']} | {fmt(p['mean_ref_' + q], 1)} | {fmt(p['mean_app_' + q], 1)} | "
                       f"{fmt(b['bias'], 1)} | {fmt(b['loa_low'], 1)} to {fmt(b['loa_high'], 1)} |")
    return "\n".join(out)


def per_record_table(d):
    out = ["| Record | Subject (age, sex) | PSG epochs scored | App 5-min windows | 5-min accuracy | 5-min κ | TST PSG / app (min) | Deep PSG / app | REM PSG / app |",
           "|---|---|---:|---:|---:|---:|---|---|---|"]
    for rec, r in d["per_record"].items():
        if not r["classified"]:
            out.append(f"| {rec} | | {r['n_scorable_30s']} | not classified | | | | | |")
            continue
        s = r["stats5"]
        rm, am = r["ref_minutes"], r["app_minutes"]
        meta = r["meta"].get("age_sex", "")
        out.append(f"| {rec} | {meta} | {r['n_scorable_30s']} | {r['n_windows_classified']} | {pct(s['accuracy'], 0)} | {fmt(s['kappa'], 2)} | "
                   f"{rm['tst']:.0f} / {am['tst']} | {rm['deep']:.0f} / {am['deep']} | {rm['rem']:.0f} / {am['rem']} |")
    return "\n".join(out)


def port_table():
    txt = open(os.path.join(HERE, "test_ports_output.txt")).read().splitlines()
    rows = {}
    for l in txt:
        m = re.match(r"(PASS|FAIL)\s+(\w+)\.", l)
        if m:
            a = rows.setdefault(m.group(2), [0, 0])
            a[1] += 1
            a[0] += m.group(1) == "PASS"
    return rows


def pub_txt(pub):
    return "n/a" if not pub["n"] else f"{pub['bias']:+.3f} (n={pub['n']})"


def main():
    s_full = load("sleep_slpdb_nn_full.json")
    s_sp = load("sleep_slpdb_nn_sp.json")
    s_all = load("sleep_slpdb_all_full.json")
    s_allsp = load("sleep_slpdb_all_sp.json")
    c_full = load("sleep_cap_nn_full.json")
    c_sp = load("sleep_cap_nn_sp.json")
    art = load("artifacts_mitdb.json")
    dfa = load("dfa_injection_nsr2db.json")
    variants = [("slpdb, NN RR, whole scored recording (primary)", s_full),
                ("slpdb, NN RR, PSG sleep period only", s_sp),
                ("slpdb, all-beat RR, whole recording", s_all),
                ("slpdb, all-beat RR, PSG sleep period only", s_allsp),
                ("CAP n1–n16 (ECG available), detected beats, whole recording", c_full),
                ("CAP n1–n16 (ECG available), detected beats, PSG sleep period only", c_sp)]
    ports = port_table()
    tpl = open(os.path.join(HERE, "RESULTS_template.md")).read()
    repl = {
        "{{PORT_TABLE}}": "\n".join(["| Swift test suite (EmuquTests @ e028039) | Cases reproduced | Cases matched |", "|---|---:|---:|"] +
                                     [f"| {k} | {v[1]} | {v[0]} |" for k, v in ports.items()]),
        "{{SLEEP_OVERALL}}": sleep_section(variants),
        "{{SLEEP_CM5}}": cm_table(s_full["pooled"]["cm5"], "Table 1b. slpdb primary analysis, pooled, 5-min epochs"),
        "{{SLEEP_CM30}}": cm_table(s_full["pooled"]["cm30"], "Table 1c. slpdb primary analysis, pooled, 30-s epochs (5-min app label upsampled)"),
        "{{SLEEP_CLASS}}": class_table(variants[:2] + variants[4:]),
        "{{SLEEP_MIN}}": minutes_table(variants[:2] + variants[4:]),
        "{{SLEEP_PER_RECORD}}": per_record_table(s_full),
        "{{SLEEP_CAP_PER_RECORD}}": per_record_table(c_full) if c_full else "_CAP analysis not available._",
        "{{SLEEP_CAP_CM5}}": cm_table(c_full["pooled"]["cm5"], "Table 1g. CAP healthy controls, pooled, 5-min epochs") if c_full else "",
    }
    p = s_full["pooled"]
    repl["{{SLPDB_PERREC_KAPPA}}"] = f"{p['per_record_kappa_mean_sd5'][0]:.3f} ± {p['per_record_kappa_mean_sd5'][1]:.3f}"
    if c_full:
        cp = c_full["pooled"]
        repl["{{CAP_PERREC_KAPPA}}"] = f"{cp['per_record_kappa_mean_sd5'][0]:.3f} ± {cp['per_record_kappa_mean_sd5'][1]:.3f}"
    # artifacts
    a = art
    rows = ["| Method (port) | Scoring rule | Sensitivity | Specificity | PPV | TP | FN | FP | TN |", "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    nm = {"ArtifactDetector": "ArtifactDetector.detectArtifacts (whole series)",
          "cleanRRForDFA": "LiveDFAAnalyzer.cleanRRForDFA mask",
          "RMSSD_pipeline": "Overnight RMSSD exclusion (ArtifactDetector + 5-min ectopic gate)"}
    for k in ("ArtifactDetector", "cleanRRForDFA", "RMSSD_pipeline"):
        for lvl in ("interval", "beat"):
            r = a["pooled"][k][lvl]
            rows.append(f"| {nm[k]} | {lvl} | {pct(r['sens'])} | {pct(r['spec'])} | {pct(r['ppv'])} | {r['tp']} | {r['fn']} | {r['fp']} | {r['tn']} |")
    repl["{{ART_DET}}"] = "\n".join(rows)
    syms = sorted(a["beat_sensitivity_by_symbol"]["ArtifactDetector"].keys())
    srows = ["| Ectopic annotation | Beats | " + " | ".join(nm[k].split(" (")[0] for k in ("ArtifactDetector", "cleanRRForDFA", "RMSSD_pipeline")) + " |",
             "|---|---:|---:|---:|---:|"]
    for sy in syms:
        n = a["beat_sensitivity_by_symbol"]["ArtifactDetector"][sy][1]
        srows.append(f"| {sy} | {n} | " + " | ".join(pct(a["beat_sensitivity_by_symbol"][k][sy][0] / n) for k in ("ArtifactDetector", "cleanRRForDFA", "RMSSD_pipeline")) + " |")
    repl["{{ART_SYM}}"] = "\n".join(srows)
    names = {"all": "All segments", "no_AF_AFL": "Excluding AF/flutter segments", "no_AF_AFL_no_ectopy": "… with no ectopic beat",
             "no_AF_AFL_with_ectopy": "… with ≥ 1 ectopic beat", "no_AF_AFL_ectopy_ge_5pct": "… with ≥ 5 % ectopic beats"}
    rr = ["| Segments | n segments (records) | Median ref RMSSD (ms) | App bias (ms) | App 95 % LoA (ms) | App ratio bias [95 % LoA] | App median abs. error (ms) | App within ±10 % | No-correction bias (ms) | No-correction ratio bias [95 % LoA] | No-correction within ±10 % |",
          "|---|---:|---:|---:|---|---|---:|---:|---:|---|---:|"]
    for k in ("all", "no_AF_AFL", "no_AF_AFL_no_ectopy", "no_AF_AFL_with_ectopy", "no_AF_AFL_ectopy_ge_5pct"):
        v = a["rmssd"][k]
        ap, rw = v["app_vs_ref"], v["raw_vs_ref"]
        ar, rr_ = v["app_vs_ref_ratio"], v["raw_vs_ref_ratio"]
        rr.append(f"| {names[k]} | {v['n_segments']} ({v['n_records']}) | {fmt(v['median_ref'], 1)} | {fmt(ap['bias'], 1)} | {fmt(ap['loa_low'], 1)} to {fmt(ap['loa_high'], 1)} | "
                  f"{fmt(ar['ratio_bias'], 2)} [{fmt(ar['ratio_loa_low'], 2)}, {fmt(ar['ratio_loa_high'], 2)}] | {fmt(v['median_abs_err_app'], 1)} | {pct(v['within10pct_app'], 0)} | "
                  f"{fmt(rw['bias'], 1)} | {fmt(rr_['ratio_bias'], 2)} [{fmt(rr_['ratio_loa_low'], 2)}, {fmt(rr_['ratio_loa_high'], 2)}] | {pct(v['within10pct_raw'], 0)} |")
    repl["{{ART_RMSSD}}"] = "\n".join(rr)
    repl["{{ART_N}}"] = f"{a['n_records']} records, {a['n_beats']:,} annotated beats, {a['n_ectopic_beats']:,} ectopic"
    # dfa
    drows = ["| Artifact type | Rate (events / intervals) | Trials | α1 bias, no correction [95 % LoA] | α1 bias, app cleanRRForDFA [95 % LoA] | MAE no corr. / app | Mean corrected fraction | Windows the app would publish (≤ 6 %) | α1 bias in published windows |",
             "|---|---:|---:|---|---|---|---:|---:|---:|"]
    for k, v in dfa["summary"].items():
        kind, rate = k.split("_")
        u, ap, pub = v["uncorrected"], v["app_corrected"], v["app_published_only"]
        drows.append(f"| {kind} | {rate} % | {v['n_trials']} | {u['bias']:+.3f} [{u['loa_low']:+.3f}, {u['loa_high']:+.3f}] | "
                     f"{ap['bias']:+.3f} [{ap['loa_low']:+.3f}, {ap['loa_high']:+.3f}] | {v['mae_uncorrected']:.3f} / {v['mae_app']:.3f} | "
                     f"{pct(v['mean_corrected_fraction'])} | {pct(v['frac_published'], 0)} | {pub_txt(pub)} |")
    repl["{{DFA_TABLE}}"] = "\n".join(drows)
    fc = dfa["false_corrections_on_normal_windows"]
    repl["{{DFA_N}}"] = (f"{dfa['n_windows']} windows from {dfa['n_records_used']} records (mean {dfa['window_beats_mean']:.0f} intervals per window; "
                         f"clean-window α1 {dfa['clean_alpha1_mean_sd'][0]:.2f} ± {dfa['clean_alpha1_mean_sd'][1]:.2f})")
    repl["{{DFA_FC}}"] = (f"Of {dfa['n_all_normal_windows']:,} artifact-free 120-s windows (every beat annotated N, every RR 300–2000 ms), "
                          f"cleanRRForDFA corrected at least one interval in {fc['n_windows']:,} ({pct(fc['share_of_all_normal_windows'])}). "
                          f"In those windows the median corrected fraction was {pct(fc['corrected_fraction_median'])}; {pct(fc['share_over_3pct'])} exceeded 3 % "
                          f"and {pct(fc['share_over_6pct'])} exceeded 6 % (α1 withheld), i.e. {pct(fc['share_over_6pct'] * fc['share_of_all_normal_windows'])} of all artifact-free windows. "
                          f"Correction changed α1 in those windows by {fc['alpha1_change']['bias']:+.3f} (95 % LoA {fc['alpha1_change']['loa_low']:+.3f} to {fc['alpha1_change']['loa_high']:+.3f}).")
    md = tpl
    for k, v in repl.items():
        md = md.replace(k, v)
    left = re.findall(r"\{\{[A-Z0-9_]+\}\}", md)
    if left:
        print("unfilled placeholders:", left)
    open(os.path.join(HERE, "RESULTS.md"), "w").write(md)
    print("wrote RESULTS.md")


if __name__ == "__main__":
    main()
