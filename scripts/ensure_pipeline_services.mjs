import { execSync } from 'node:child_process';
import http from 'node:http';

async function checkCdp() {
  return new Promise((resolve) => {
    const req = http.get('http://127.0.0.1:9222/json/version', (res) => {
      resolve(res.statusCode === 200);
    });
    req.on('error', () => resolve(false));
    req.setTimeout(1000, () => {
      req.destroy();
      resolve(false);
    });
  });
}

async function main() {
  console.log('[Self-Check] Проверка состояния сервисов циклического пайплайна...');
  
  // 1. Check CDP port 9222
  const cdpOk = await checkCdp();
  if (cdpOk) {
    console.log('  🟢 Chrome CDP (порт 9222): Доступен');
  } else {
    console.log('  ⚠️ Chrome CDP (порт 9222): Не отвечает. Убедитесь, что Chrome запущен с --remote-debugging-port=9222');
  }

  // 2. Run supervisor --ensure
  try {
    const output = execSync('python C:\\Scripts\\agentic_cyclic_supervisor.py --ensure', {
      encoding: 'utf-8',
      windowsHide: true
    });
    console.log('  🟢 Супервизор сервисов:');
    for (const line of output.trim().split('\n')) {
      console.log(`     ${line}`);
    }
  } catch (err) {
    console.error('  ❌ Ошибка вызова супервизора:', err.message);
  }
}

main();
