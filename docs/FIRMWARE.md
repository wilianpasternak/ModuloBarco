# Firmware PescaPlus (ESP-IDF)

ESP32 DevKit Classic · ESP-IDF 5.5.5 · PlatformIO (`espressif32 @ 8.0.0`) · NimBLE (esp-nimble-cpp 2.6)

## Arquitetura

| Núcleo | Task | Prio | Período | Função |
|---|---|---|---|---|
| 1 | `control` | 10 | 20 ms (50 Hz) | Dona do estado e dos motores. Consome a fila de comandos; âncora, norte, aponta-norte, calibração, rampas, holds |
| 1 | `compass` | 9 | 20 ms | HMC5883L (I2C 50 kHz, sensor a 75 Hz) + filtro de rumo e velocidade de giro |
| 1 | `gps` | 8 | por evento | UART2 38400 / 5 Hz + TinyGPSPlus; publica posição |
| 0 | NimBLE | sistema | — | GATT `ffe0` (`ffe1` comandos/telemetria, `ffe2` OTA) |
| 0 | `remote` | 7 | 10 ms | nRF24L01 (polling, IRQ não conectado) → fila de comandos |
| 0 | `ota` | 5 | por evento | Grava os chunks do OTA na flash, fora da task BLE |
| 0 | `telemetry` | 3 | 500 ms | Telemetria BLE; bateria a cada 3 s |
| 0 | `buzzer` | 2 | por evento | Padrões de bip sem bloquear |
| 0 | `settings` | 1 | por evento | Grava NVS com debounce de 1 s |

O BLE e o NRF não mexem em nada diretamente: eles só convertem o comando e o colocam
na **fila única** (`commands.h`). A `control_task` processa cada comando assim que ele chega
e roda o ciclo periódico a cada 20 ms.

| Arquivo | Conteúdo |
|---|---|
| `src/main.cpp` | Versão, ordem de boot, autoteste/rollback |
| `src/config.h` | Pinos, constantes, prioridades e núcleos |
| `src/control.*` | Lógica de controle: manual, norte, aponta-norte, calibração, rampas, holds |
| `src/anchor.*` | Âncora virtual (Kalman + controle vetorial) |
| `src/steer.*`, `src/heading_filter.h` | Controle do motor de giro em cascata e filtro do rumo |
| `src/commands.*` | Protocolo de texto `$XXX` → comando |
| `src/ble.*`, `src/ota.*` | GATT, notificações e OTA |
| `src/compass.*`, `src/gps.*`, `src/nrf24.*`, `src/remote.*` | Sensores e rádio |
| `src/motors.*`, `src/buzzer.*`, `src/telemetry.*`, `src/settings.*` | Saídas, bateria, NVS |
| `components/TinyGPSPlus` | TinyGPSPlus 1.1.0 (LGPL-2.1) adaptada sem Arduino |

### Mudanças de comportamento em relação ao firmware Arduino (1.1.x)
- **Calibração da bússola** sem bloqueio: BLE e telemetria continuam funcionando durante os ~22 s.
  Só os comandos de consulta são aceitos nesse tempo. Cada lado gira `calibTimeSeg` inteiros
  (antes o primeiro lado perdia 1 s).
- **Âncora reescrita** (controle vetorial 2D com Kalman). Veja a seção "Âncora virtual".
- Os `delay(300/2000)` do controle NRF viraram janelas em que os pacotes são ignorados, sem travar o sistema.
- `$NRT` com a âncora ativa agora desliga a âncora corretamente: zera a hélice e o giro.
- O aponta-norte não sofre mais o "pulso" de 0 a cada 150 ms causado pelo timeout de hold do NRF.
- PID, Kalman e ângulos usam `float` (o ESP32 tem FPU só de precisão simples). Lat/lon e haversine continuam em `double`.
- A NVS grava com debounce de 1 s (antes, cada clique em `$HMN±` gravava). A calibração e os controles gravam na hora.
- Se o nRF24 parar de responder, o firmware tenta reinicializá-lo a cada 5 s.
- Watchdog de 3 s na `control_task`: se ela travar, o ESP reinicia e os motores sobem desligados.

O protocolo BLE (comandos, respostas, telemetria, UUIDs) e as chaves da NVS **não mudaram**.
O único ponto novo é o nome BLE, que passou a ser **`PescaPlus`**.

## Âncora virtual (`src/anchor.cpp`)

1. **Posição filtrada:** filtro de Kalman por eixo (Norte/Leste em metros), usando a posição
   do GPS e a **velocidade Doppler** (RMC) como medidas. O peso da posição segue o HDOP.
   Fixes com HDOP acima de 5 são descartados.
2. **Ponto da âncora:** média dos primeiros 15 fixes (~3 s) após ativar.
3. **Empuxo desejado** (vetor, em PWM):
   - `integral(Ki·erro)`: aprende a força e a direção do vento/correnteza;
   - `max(0, Kp·dist − Kd·v_aproximação)` na direção do ponto: **nunca negativo**. Sem ré,
     frear girando 180° custa segundos sem empuxo, então quem freia é o arrasto da água;
   - `−0,5·Kd·v_lateral`: amortece a deriva lateral.
4. **Giro:** aponta o motor na direção desse vetor, com histerese (começa a 10°, para a 4°).
   O sentido fica travado por manobra e respeita o limite do cabo (±300°). Isso corrigiu um bug
   do firmware antigo, em que o giro "tremia" no limite do cabo e parava o motor.
5. **Hélice:** `força × cos(erro de rumo)`, até 60°. Abaixo do PWM mínimo, liga e desliga em
   ciclos de 2 s (duty cycle) para entregar forças pequenas. A subida é limitada a 150 PWM/s.
6. **Failsafe:** 2 s sem fix bom → hélice e giro parados, 3 bipes longos e aviso no app.
   O ponto é mantido e a âncora retoma sozinha quando o GPS volta.
7. **Bússola:** a calibração agora corrige também a escala por eixo (soft-iron), além do centro.
   A declinação magnética continua no **offset de heading** (`$HOF`); no Brasil ela fica entre
   −15° e −23°, conforme a região.

Ganhos padrão: **Kp 60 · Ki 5 · Kd 30**, ajustáveis em *Opções Avançadas → Âncora — Ajuste Fino*.
Ficam salvos na NVS. Um único conjunto serve para a faixa de 300 a 700 kg com motores de 54 e 65 lb.
Os ganhos são em PWM, então um barco mais pesado ou um motor mais fraco só "sente" a âncora um pouco
mais suave. A força aprendida contra a correnteza vai até 230 PWM, o suficiente para 700 kg com
54 lb em correnteza de ~0,8 m/s.

Simulação (300–700 kg + massa de água, arrasto proporcional ao casco, 54 lb ≈ 240 N e 65 lb ≈ 289 N,
giro de 45°/s, ruído e erro de 5° na bússola, atraso de 0,5 s no ESC, GPS com ruído de 0,8 m,
5 sementes por cenário). Valores em RMS / máximo:

| Barco | Antigo, água parada | Antigo, 0,5 m/s | Novo, água parada | Novo, 0,5 m/s |
|---|---|---|---|---|
| 300 kg · 65 lb | 1,29 / 2,8 m | 2,74 / 4,8 m | 0,82 / 2,5 m | 0,80 / 2,1 m |
| 500 kg · 54 lb | 1,37 / 2,7 m | 4,02 / 6,1 m | 0,97 / 2,2 m | 0,97 / 2,4 m |
| 700 kg · 54 lb | 1,33 / 2,6 m | 4,65 / 6,4 m | 1,05 / 2,4 m | 1,06 / 2,5 m |
| 700 kg · 54 lb, 0,8 m/s | — | 7,08 / 8,8 m | — | 1,24 / 2,8 m |

São números de modelo, não da água: servem para comparar as duas lógicas, e o ajuste final é feito no barco.

### Protocolo BLE adicionado
| Comando | Resposta | Uso |
|---|---|---|
| `$APG?` | `$APG:<kp×10>:<ki×10>:<kd×10>` | Lê os ganhos |
| `$APK:<n>` `$API:<n>` `$APD:<n>` | `$APG:...` | Ajusta Kp, Ki ou Kd (valor ×10) |
| `$APR` | `$APG:...` | Restaura os padrões |
| — | `$ANS:<dist>:<vel>:<força>:<dir_força>:<hdop>:<sem_gps>:<hélice>` | Estado da âncora a cada 500 ms (só com a âncora ativa) |
| — | `$GTV:1` / `$GTV:0` | Motor de giro travou / voltou a girar |
| `$CAL` | `$CAL:1` → `$CAL:2` → `$CAL:OK` ou `$CAL:ERR:<motivo>` | Calibração: girando → verificando → resultado |
| — | `$BSC:<0..3>` | Estado da bússola (ok / não calibrada / inválida / ausente) |

## Calibração da bússola (obrigatória no motor instalado)

O ferro e os ímãs do próprio motor deslocam e achatam o círculo de leituras do magnetômetro. Sem
calibração, faixas inteiras do rumo nunca aparecem: por exemplo, lê de 0 a 120°, "some" até 200°
e volta depois.

Sequência (`$CAL` pelo app ou pela combinação do controle no cadastro):
1. **Calibra:** gira `calibTimeSeg` s para cada lado coletando mínimo e máximo de X e Y.
   Daí saem o **centro** (hard-iron) e a **escala por eixo** (soft-iron).
2. **Confere a coerência:** os dois eixos precisam ter amplitude real (o motor girou) e
   proporção entre 0,5 e 2.
3. **Aplica** a calibração nova às leituras.
4. **Verifica:** dá **1,5 volta para a esquerda e 1,5 volta para a direita** lendo o rumo já
   calibrado, sem filtro. Em **cada sentido** exige:
   - leituras nos **12 setores de 30°**;
   - **nenhum salto** maior que 20° entre leituras consecutivas (o "buraco" aparece como salto);
   - **intensidade do campo uniforme** (máximo/mínimo ≤ 2). Pega calibração feita em outra
     posição ou peça metálica nova;
   - a volta e meia completa em até 25 s.
5. **Aprovada:** grava na NVS e soam 3 bipes; o app mostra "Bússola calibrada".
   **Reprovada:** **restaura a calibração anterior** (nada é gravado), soam 1 bipe longo e
   3 curtos, e o app explica o motivo.

Com o modelo de magnetômetro usado no teste (ímã do motor deslocando o círculo além do campo
da Terra), a verificação reprova a bússola sem calibração (só os setores de 270–359° aparecem) e
reprova uma calibração deslocada (campo 4,5× irregular). A boa calibração é aprovada, com erro
de rumo ≤ 3,4°.

### Bloqueio e monitor da calibração
- **Âncora, norte e aponta-norte só ativam com a bússola calibrada e válida.** Caso contrário,
  soam 1 bipe longo, 1 curto e 1 longo, e o app avisa o motivo.
- **Monitor em uso:** com a calibração correta, a intensidade do campo lido (já corrigido) é
  igual à da calibração em qualquer rumo. Se ela se afastar mais de 30% por 3 s (motor
  reinstalado, peça metálica perto, interferência), a calibração passa a **inválida**.
  Os modos automáticos ativos são desligados com segurança: hélice e giro param. O app pede para
  recalibrar. Se o campo voltar ao normal (±20% por 3 s), o estado volta a OK.
- Estados (`$BSC:<n>`): **1** ok · **0** não calibrada · **2** calibração inválida · **3** bússola
  não encontrada. É enviado na conexão, no `$CFG?`, em cada mudança e em cada bloqueio. O app mostra
  o estado em *Config → Calibrar Bússola*.
- Calibrações feitas antes desta versão não têm a intensidade de referência. Nelas o monitor fica
  inativo até a próxima calibração (a primeira gravação via USB apaga tudo de qualquer forma).

## Controle do motor de giro (`src/steer.cpp`)

É usado pela âncora, pelo modo norte e pelo aponta-norte. O giro manual (botões) continua com o PWM fixo de uso.

1. **Malha de ângulo:** velocidade de giro desejada = 2,5°/s por grau de erro, entre 10 e 110°/s.
   Giros grandes saem no PWM máximo, e o motor desacelera sozinho perto do alvo.
2. **Malha de velocidade:** a bússola gira com o motor, então a variação do rumo é a velocidade
   real do giro. PWM = partida aprendida + parcela proporcional à velocidade pedida + PI do erro
   de velocidade. **Se o motor não gira, o PWM sobe sozinho** até vencer o atrito.
3. **PWM de partida aprendido:** começa em 90 (`GIRO_PWM_START`) e se adapta ao PWM com que o
   motor efetivamente começa a girar. Ele sobe com a hélice empurrando, com o cabo torcido etc.
4. **Proteção:** 2 s no PWM máximo sem girar → corta o giro, 2 bipes longos e o app avisa
   "Motor de giro travado". Nova tentativa em 5 s.
5. **Zonas por modo** (começa a corrigir / considera alinhado / intervalo entre manobras):
   - âncora: 10° / 3° / 1,5 s;
   - norte: 5° / 2°;
   - aponta-norte: 4° / 1,5°.

   Na âncora a precisão é limitada pelo GPS (10° de erro custam só 1,5% de empuxo). Uma zona
   larga dá a mesma precisão com ~40% menos tempo de giro ligado.

Resultado da simulação (motor com atrito de partida de 90–200 PWM e ~100°/s no máximo, bússola com ruído):

| Situação | Giro antigo (150/220 fixo) | Cascata |
|---|---|---|
| Correção de 30° | 0,76 s, passa 5° do alvo, erro final 5° | 0,44 s, passa 3°, erro final 2° |
| Giro de 170° | 2,7 s, erro final 4,5° | ~1,9 s, erro final ~1° |
| Atrito alto (200 PWM: cabo torcido) | **não gira** (erro de 30–49°) | gira; erro final ~1° |
| Modo norte, barco guinando ±30° | erro de rumo 8,5° RMS (pico 19,6°) | 4,4° RMS (pico 11,5°) |
| Âncora (frota 300–700 kg) | 0,94 m RMS, giro ligado 77 s em 9 min | 0,93 m RMS, giro ligado 49 s |

**Convenção:** PWM no pino "direita" faz o rumo da bússola **aumentar**. Se a ligação estiver
invertida, o controle nunca vê o motor girando no sentido certo e indica "giro travado" logo no
primeiro uso. Nesse caso, inverta os fios do motor de giro.

## Chave de assinatura (IMPORTANTE)

O OTA só aceita firmware assinado (ECDSA P-256) com `pescaplus_signing_key.pem`.

- O arquivo fica na raiz do projeto e está no `.gitignore`. **Nunca commite nem envie esse arquivo.**
- **Faça backup agora** (gerenciador de senhas, pendrive guardado etc.).
- **Se a chave for perdida, nenhum barco aceita mais OTA**: só regravando via USB com um firmware de chave nova.
- Sem a chave, o build falha de propósito (`scripts/sign_firmware.py`), para impedir que um firmware não assinado seja publicado.

Para gerar uma chave nova (só se a atual vazar ou for perdida):
```sh
~/.platformio/packages/tool-esptool/espsecure generate-signing-key --version 1 pescaplus_signing_key.pem
```

O script de build extrai a chave pública da privada e a embute no firmware. Depois assina o
`firmware.bin`. O bootloader não verifica a assinatura (não há Secure Boot), então o mesmo arquivo
também grava normalmente via USB. Para conferir:
```sh
~/.platformio/packages/tool-esptool/espsecure verify-signature --version 1 \
  --keyfile pescaplus_signing_key.pem .pio/build/esp32/firmware.bin
```

## Primeira gravação (USB) — obrigatória

O bootloader e a tabela de partições mudaram, e isso o OTA não atualiza. Na primeira vez:
```sh
pio run -e esp32 -t erase     # apaga a flash inteira (inclui a NVS antiga)
pio run -e esp32 -t upload    # grava bootloader + partições + app
pio device monitor -e esp32
```
Como a flash foi apagada, refaça depois a calibração da bússola, o cadastro dos controles, o PWM mínimo da hélice etc.

Partições (4 MB): `nvs` 20 KB · `otadata` 8 KB · `app0` 1,94 MB · `app1` 1,94 MB.

## OTA e rollback

1. O app envia `OTA_START:<tam>:<versão>:<md5>`, depois os chunks e por fim `OTA_END`.
2. O motor verifica:
   - o cabeçalho (chip ESP32 e `project_name` = `PescaPlus`);
   - o tamanho e o MD5;
   - a **assinatura**.

   Só então troca a partição de boot e responde `OTA_OK`. Em caso de erro responde `OTA_ERR:<motivo>`.
3. O firmware novo sobe "em teste". Depois de 10 s rodando o controle sem falhas, ele se confirma.
   Se reiniciar antes disso (crash ou watchdog), o bootloader **volta para a versão anterior** sozinho.
4. O app reconecta sozinho, compara a versão informada (`$VER`) com a esperada e mostra o resultado
   (sucesso ou rollback).

## Release

`bash scripts/release.sh` faz o build e confere a assinatura antes de publicar (aborta se ela for
inválida). Depois publica no GitHub e atualiza o `firmware_latest.json`.

## Configuração do ESP-IDF

A configuração base está em `sdkconfig.defaults`. O PlatformIO gera `sdkconfig.esp32` a partir dele
**só quando esse arquivo não existe**. Por isso, depois de editar `sdkconfig.defaults`, apague
`sdkconfig.esp32` antes de compilar. Para ver os logs de depuração (GPS, NRF, âncora), use
`CONFIG_LOG_DEFAULT_LEVEL_DEBUG=y`.

## Roteiro de testes de bancada

Marque cada item e me mande o log do monitor serial quando algo falhar.

**Boot e BLE**
- [ ] Erase + upload via USB; o log mostra `PescaPlus — firmware 2.0.0` e `Pronto.`
- [ ] Relés não estalam no boot; hélice e giro parados; 3 bipes de boot
- [ ] O app encontra o motor como **PescaPlus**, conecta e mostra versão 2.0.0, bateria e PWM mínimo
- [ ] Telemetria atualiza (heading, GPS, satélites) a cada ~0,5 s

**Comandos pelo app**
- [ ] Giro E/D enquanto o botão está pressionado; para ao soltar e quando a conexão cai
- [ ] Sobe/desce (relés) da mesma forma
- [ ] Motor ON com rampa de 1,5 s; aceleração +/- com o incremento configurado
- [ ] PWM mínimo +/- move a hélice e persiste após reboot
- [ ] Offset de heading, buzzer on/off e config. avançada persistem após reboot

**Controle NRF**
- [ ] Cadastro: ligar com o botão do slot pressionado (janela de 1 s) e cadastro pelo app (`$RGE`)
- [ ] Controle cadastrado comanda giro, sobe/desce e motor; controle não cadastrado recebe 3 bipes curtos
- [ ] Bateria do controle aparece no app; remover controle pelo app
- [ ] Âncora e norte pelo controle (sem repetição ao segurar o botão)
- [ ] Desligar/religar o nRF24 com o motor ligado: ele volta a funcionar sozinho em até ~5 s

**Motor de giro (cascata)**
- [ ] Modo norte: corrige pequenos desvios com suavidade, sem passar do rumo e voltar
- [ ] Aponta-norte: para em 0° ± 2°
- [ ] Segurar a cabeça do motor com a mão durante uma correção: depois de ~2 s o giro corta, soam 2 bipes longos e o app mostra "Motor de giro travado"; ao soltar, ele volta em 5 s
- [ ] Com a hélice em força alta, o giro ainda alinha (o PWM de partida sobe sozinho)

**Bússola e GPS**
- [ ] Sem calibração (logo após a gravação USB): tentar âncora ou norte → bloqueado, com bipes e aviso no app
- [ ] Depois de calibrar: aproximar uma ferramenta de aço da cabeça do motor por ~5 s → "Calibração inválida", e um modo automático ativo é desligado; afastar → volta a "Bússola calibrada"
- [ ] Calibração pelo app: gira para cada lado e depois 1,5 volta para cada lado. O diálogo mostra "Calibrando" → "Verificando" → "Bússola calibrada"
- [ ] Reprovação proposital: calibre com uma ferramenta metálica perto da bússola e retire depois, ou segure a cabeça do motor durante a verificação. Deve aparecer "Calibração reprovada" com o motivo, e o rumo continua o da calibração anterior
- [ ] Calibração pela combinação do controle: 3 bipes se aprovada; 1 longo e 3 curtos se reprovada
- [ ] Offsets mantidos após reboot; heading coerente com uma bússola de referência
- [ ] Aponta-norte para em 0° ± 5° sem trepidar
- [ ] GPS a 5 Hz (log em nível DEBUG: `rate=5.00Hz`)

**Água — âncora**
- [ ] Antes: ajuste o offset de heading (`$HOF`) até que o rumo do motor bata com o rumo verdadeiro (inclui a declinação local)
- [ ] Ativar: o cartão "Do ponto / Correnteza / Precisão GPS" aparece no app
- [ ] Água parada: o barco fica a menos de ~1,5 m do ponto, sem "orbitar"
- [ ] Com correnteza ou vento: após ~30–60 s a "Correnteza" estabiliza e o motor fica apontado contra ela, sem dente de serra
- [ ] Passou do ponto e voltou? Aumente o **Freio** ou reduza a **Força**. Demora a reagir? Aumente a **Força**
- [ ] Cobrir a antena do GPS: depois de 2 s, a hélice para, aparece "SEM GPS" e soam 3 bipes; descobrir: a âncora retoma
- [ ] Qualquer comando desativa a âncora (1 bipe longo)
- [ ] Modo norte mantém o rumo; giro/sobe/desce o desativam

**OTA**
- [ ] OTA de 2.0.0 para uma 2.0.1 de teste: o app mostra as etapas, reconecta sozinho e confirma "Atualização concluída"
- [ ] OTA de um `firmware.bin` **sem assinatura** (ou assinado com outra chave): o app mostra "assinatura inválida" e o motor continua na versão atual
- [ ] Rollback: publique uma versão de teste que trava no boot (ex.: `abort()` no `app_main`). O app deve informar que o motor voltou para a versão anterior
- [ ] Desligar o Bluetooth do celular no meio do envio: o motor descarta a atualização e segue na versão atual
