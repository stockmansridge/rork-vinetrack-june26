#!/usr/bin/env python3
"""Bounded regression for build 189's production getter cycle.

Reads the shipping Swift view; executes its exact area-basis fragment in a
Swift host harness. UI/store boundaries are synthetic, not a native UI test.
Run: python3 -m unittest discover -s scripts/tests -p test_spray_product_recursion.py -v
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / 'ios/VineTrack/App/SprayCalculatorView.swift'
ENGINE = ROOT / 'ios/VineTrack/App/SprayEngine/SprayGuidedFlow.swift'


def masked(source):
    # Preserve character positions while removing comments and string literals.
    pattern = r'/\*[\s\S]*?\*/|//[^\n]*|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"'
    return re.sub(pattern, lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), source)


def block(source, start):
    clean = masked(source)
    opening = clean.index('{', start)
    depth = 1
    i = opening + 1
    while depth and i < len(clean):
        depth += (clean[i] == '{') - (clean[i] == '}')
        i += 1
    if depth:
        raise AssertionError('Unbalanced production source')
    return source[opening + 1:i - 1]


def properties(source):
    body = block(source, source.index('struct SprayCalculatorView: View'))
    return {m[1]: block(body, m.start()) for m in re.finditer(
        r'(?m)^    private var (\w+)\s*:[^={\n]+\{', masked(body))}


def host_source(fragment):
    return r'''
import Foundation

enum OperationType: CaseIterable { case foliarSpray, bandedSpray, spreader, fertigation, unsupported }
enum ChemicalRateBasis: CaseIterable { case perHectare, per100Litres }
enum SprayProductRateBasis { case wholeBlockArea, treatedArea, per100Litres }
struct Record { let isTemplate: Bool }
struct Line { let id: Int; let basis: ChemicalRateBasis }
struct Product { let basis: SprayProductRateBasis; let explicit: Bool }
struct Inputs { let operationType: OperationType; let products: [Product] }
struct Flow {
    let inputs: Inputs
    var requiresBandWidth: Bool { inputs.operationType == .bandedSpray }
}
final class Probe {
    var operationType: OperationType = .foliarSpray
    var prefillRecord: Record? = nil
    var productAreaBasis: [Int: SprayProductRateBasis] = [:]
    var lines: [Line] = []
    var reads = 0
    var depth = 0
    var flow: Flow {
        depth += 1
        reads += 1
        // Do not exhaust a host stack: fail on the third recursive entry.
        if depth >= 3 {
            print("RECURSIVE_PRODUCT_FLOW: flow -> guidedInputs -> guidedProductLines -> flow")
            exit(86)
        }
        defer { depth -= 1 }
        return Flow(inputs: guidedInputs)
    }
    var guidedInputs: Inputs {
        Inputs(operationType: operationType, products: guidedProductLines)
    }
    var guidedProductLines: [Product] {
        lines.map { line in
''' + fragment + r'''
            return Product(basis: basis, explicit: chosenAreaBasis != nil)
        }
    }
}
let probe = Probe()
precondition(probe.flow.inputs.products.isEmpty)
precondition(probe.reads == 1)
var cases = 1
let prefills: [Record?] = [nil, Record(isTemplate: true), Record(isTemplate: false)]
let overrides: [SprayProductRateBasis?] = [nil, .wholeBlockArea, .treatedArea]
for operation in OperationType.allCases {
    for prefill in prefills {
        for rateBasis in ChemicalRateBasis.allCases {
            for override in overrides {
                probe.operationType = operation
                probe.prefillRecord = prefill
                probe.productAreaBasis = override.map { [1: $0] } ?? [:]
                probe.lines = [Line(id: 1, basis: rateBasis)]
                probe.reads = 0
                let products = probe.flow.inputs.products
                precondition(probe.reads == 1, "Flow construction must be bounded")
                precondition(products.count == 1)
                let newPlan = prefill == nil || prefill?.isTemplate == true
                let expectedDefault: SprayProductRateBasis? = newPlan && operation == .bandedSpray && rateBasis == .perHectare ? .treatedArea : nil
                let expectedChoice = override ?? expectedDefault
                let expected: SprayProductRateBasis = rateBasis == .per100Litres ? .per100Litres : (expectedChoice ?? .wholeBlockArea)
                precondition(products[0].basis == expected, "Dose-area basis changed")
                precondition(products[0].explicit == (expectedChoice != nil))
                cases += 1
            }
        }
    }
}
probe.prefillRecord = nil
probe.operationType = .bandedSpray
probe.productAreaBasis = [:]
probe.lines = [Line(id: 1, basis: .per100Litres), Line(id: 2, basis: .perHectare)]
for _ in 0..<20 {
    probe.reads = 0
    let products = probe.flow.inputs.products
    precondition(probe.reads == 1 && products.count == 2)
    precondition(products[0].basis == .per100Litres && products[1].basis == .treatedArea)
    cases += 1
}
print("PASS: \(cases) production-expression scenarios; no recursive flow construction")
'''


class SprayProductRecursionTests(unittest.TestCase):
    def test_production_projection_never_reads_flow(self):
        projection = properties(VIEW.read_text())['guidedProductLines']
        self.assertNotRegex(masked(projection), r'\bflow\b',
            'Building a flow input cannot read the flow that consumes it')

    def test_flow_input_dependency_graph_is_acyclic(self):
        props = properties(VIEW.read_text())
        edges = {key: set(re.findall(r'(?<![\w.])\b\w+\b', masked(value))) & props.keys()
                 for key, value in props.items()}
        def visit(key, path):
            self.assertNotIn(key, path, ' -> '.join(path + [key]))
            for child in sorted(edges[key]):
                visit(child, path + [key])
        visit('flow', [])

    def test_band_width_rule_remains_leaf_operation_predicate(self):
        engine = ENGINE.read_text()
        body = block(engine, engine.index('var requiresBandWidth:'))
        self.assertEqual(body.strip(), 'inputs.operationType == .bandedSpray')

    def test_production_expression_preserves_area_rules_and_terminates(self):
        source = VIEW.read_text()
        projection = properties(source)['guidedProductLines']
        start = projection.index('let newSpray =')
        end = projection.index('// THE label rate', start)
        fragment = projection[start:end]
        self.assertIn('let chosenAreaBasis =', fragment)
        self.assertIn('let basis: SprayProductRateBasis =', fragment)
        compiler = shutil.which('swiftc')
        if compiler is None:
            self.skipTest('Swift compiler not installed; native acceptance still required')
        with tempfile.TemporaryDirectory(prefix='vinetrack-crash189-') as directory:
            path = Path(directory)
            fixture = path / 'main.swift'
            fixture.write_text(host_source(fragment))
            compiled = subprocess.run([compiler, str(fixture), '-o', str(path / 'probe')],
                capture_output=True, text=True, timeout=35)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(path / 'probe')], capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('PASS: 111 production-expression scenarios', run.stdout)


if __name__ == '__main__':
    unittest.main()
