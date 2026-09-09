"""Verify consumer visibility and intentional non-Codable voice configuration."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
subprocess.run(['swift', 'build'], cwd=root, check=True)
bin_path = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip()
command = ['xcrun', 'swiftc', '-typecheck', '-swift-version', '6', '-I', str(Path(bin_path) / 'Modules')]
subprocess.run(command + [str(root / 'Fixtures/ExternalConsumer.swift')], check=True)
with tempfile.TemporaryDirectory(prefix='mercurykit-api-') as temp:
    for constraint in ('Encodable', 'Decodable'):
        path = Path(temp) / (constraint + '.swift')
        path.write_text('import MercuryKit\nfunc requires<T: ' + constraint + '>(_ type: T.Type) {}\nrequires(VoiceClientConfig.self)\n')
        result = subprocess.run(command + [str(path)], capture_output=True, text=True)
        expected = "requires that 'VoiceClientConfig' conform to '" + constraint + "'"
        if result.returncode == 0 or expected not in result.stderr:
            raise RuntimeError('Unexpected negative compile result: ' + result.stderr)
        print('PASS: VoiceClientConfig rejects ' + constraint)
print('PASS: external consumer imports and required helper API')
