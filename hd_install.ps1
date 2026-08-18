# Dead Air x64 — установка HD-текстур.
#
# Кладётся в папку с игрой (туда, где database и fsgame.ltx) и запускается.
#
# Набор весит 2.7 ГБ и приезжает четырьмя частями. Части качаются, проверяются и распаковываются
# ПО ОДНОЙ, и каждая удаляется сразу после распаковки. Поэтому на диске в любой момент лежит
# не 2.7 ГБ загрузки, а одна часть — меньше гигабайта. Оборванная загрузка продолжается с того
# места, где встала: докачивается только незавершённая часть, уже поставленные не трогаются.
#
# Что уже поставлено, помнит da_hd_parts.txt. Файлы игры, которые набор перекрывает, уносятся
# в резерв — снятие набора возвращает их на место. Ничего чужого скрипт не удаляет: он знает
# ровно тот перечень, который сам поставил.

$ErrorActionPreference = 'Stop'

# --- СОВМЕСТИМОСТЬ СО СТАРЫМИ WINDOWS -------------------------------------------------------
# GitHub принимает только TLS 1.2, а Windows 7 и ранние сборки Windows 10 по умолчанию
# предлагают TLS 1.0 — соединение обрывается ещё до запроса, с невнятной ошибкой.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host ''
    Write-Host '  Нужен PowerShell версии 3.0 или новее.' -ForegroundColor Red
    Write-Host "  У вас: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-Host ''
    Write-Host '  На Windows 7 он ставится обновлением Windows Management Framework:'
    Write-Host '  https://www.microsoft.com/download/details.aspx?id=54616'
    Write-Host ''
    Read-Host 'Enter — выход'
    exit 1
}

# --- ВЫВОД ----------------------------------------------------------------------------------
# Определения стоят ЗДЕСЬ, выше всего остального. PowerShell выполняет файл сверху вниз, и функция
# существует только после того, как строка с её определением выполнена: спасательная ветка,
# зовущая Say раньше, чем Say объявлен, роняет скрипт вместо того, чтобы спасать.
function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Fail($text) { Say ''; Say "ОШИБКА: $text" 'Red'; Say ''; Read-Host 'Enter — выход'; exit 1 }
# PowerShell 5.1 в Set-Content -Encoding UTF8 ставит BOM в начало файла. Для отметок это не
# косметика, а поломка: строка версии становится не равна самой себе, а первая строка перечня
# частей перестаёт опознаваться — и уже поставленная часть качается заново, все 680 МБ.
# Пишем через .NET с явным «без BOM», а на чтении BOM снимаем: у тех, кто ставил прежней
# версией лаунчера, отметки уже с ним.
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
function WriteText($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8NoBom) }
function AppendText($path, $line) {
    $prev = ''
    if (Test-Path $path) { $prev = [IO.File]::ReadAllText($path) }
    [IO.File]::WriteAllText($path, $prev + $line + "`r`n", $Utf8NoBom)
}
function ReadLines($path) {
    if (-not (Test-Path $path)) { return @() }
    @([IO.File]::ReadAllText($path) -split "`r?`n" | ForEach-Object { $_.Trim([char]0xFEFF).Trim() } | Where-Object { $_ })
}

function Speed($bps) {
    if ($bps -ge 1048576) { '{0:n1} МБ/с' -f ($bps / 1048576) }
    else                  { '{0:n0} КБ/с' -f ($bps / 1024) }
}
function Left($sec) {
    if ($sec -ge 3600) { '{0:n0} ч {1:n0} мин' -f [math]::Floor($sec/3600), (($sec % 3600)/60) }
    elseif ($sec -ge 60) { '{0:n0} мин' -f [math]::Ceiling($sec/60) }
    else { '{0:n0} сек' -f $sec }
}
function Size($bytes) {
    if ($bytes -ge 1073741824) { '{0:n2} ГБ' -f ($bytes / 1073741824) }
    else                       { '{0:n0} МБ' -f ($bytes / 1048576) }
}

# --- КУДА СМОТРЕТЬ --------------------------------------------------------------------------
$Owner = 'DeadAir-x64'
$Repo  = 'Dead-Air-x64-HD'

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Work      = Join-Path $env:TEMP 'da_hd'
$AppData   = Join-Path $Root 'appdata'
$StampFile = Join-Path $AppData 'da_hd_version.txt'
$PartsFile = Join-Path $AppData 'da_hd_parts.txt'
$FilesFile = Join-Path $AppData 'da_hd_files.txt'
$BackupDir = Join-Path $AppData 'da_hd_backup'
$OurFiles  = Join-Path $AppData 'da_x64_files.txt'   # манифест самой сборки x64

$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'

Say ''
Say '  Dead Air x64 — HD-текстуры' 'Cyan'
Say '  --------------------------' 'Cyan'
Say ''

# --- 1. Это вообще Dead Air? ----------------------------------------------------------------
if (-not (Test-Path (Join-Path $Root 'database\levels.xdb0'))) {
    Fail @"
Рядом со скриптом нет папки database с архивами игры.
Положите этот файл в корень установленной Dead Air — туда, где лежат
fsgame.ltx и папка database, — и запустите ещё раз.
"@
}
if (Get-Process xrEngine -ErrorAction SilentlyContinue) {
    Fail 'Игра запущена. Закройте её и запустите установку заново.'
}

# --- 2. Есть ли чем распаковывать? ----------------------------------------------------------
# tar входит в состав Windows 10 сборки 1803 и новее. На Windows 7 и ранних Windows 10 его нет,
# и подсунуть замену нечем — набор в формате .tar.xz, а встроенный распаковщик ZIP его не поймёт.
# Честно говорим об этом СЕЙЧАС, а не после того, как человек скачает 2.7 ГБ.
if (-not (Test-Path $Tar)) {
    Fail @"
В системе нет tar.exe — им распаковывается набор.

tar входит в Windows 10 начиная со сборки 1803 и в Windows 11.
На более старых системах скачайте части вручную со страницы

  https://github.com/$Owner/$Repo/releases/latest

и распакуйте их 7-Zip в корень игры.
"@
}

# --- 3. Сколько места надо ------------------------------------------------------------------
# После распаковки набор занимает 4.0 ГБ. Плюс одна часть загрузки на диске в моменте — меньше
# гигабайта, потому что части удаляются сразу после распаковки. Просим 6 ГБ с запасом:
# распаковка в переполненный диск обрывается на середине и оставляет половину набора.
$drive = (Get-Item $Root).PSDrive
if ($drive.Free -lt 6GB) {
    Fail @"
На диске $($drive.Name): свободно $(Size $drive.Free), а нужно не меньше 6 ГБ.

Набор занимает 4.0 ГБ после распаковки, остальное — запас на загрузку.
"@
}

# --- 4. Потянет ли видеокарта ---------------------------------------------------------------
# Набор — это память, а не работа на кадр: частота почти не меняется, пока памяти хватает.
# Как только кончилась, драйвер начинает гонять текстуры туда-сюда, и игра дёргается.
# Замер на Баре: 819 МБ штатных текстур против 1458 МБ с набором, то есть +639 МБ.
#
# Объём видеопамяти берём из реестра, а не из WMI: WMI отдаёт AdapterRAM 32-битным числом,
# и всё, что больше 4 ГБ, приезжает обрезанным — 6 ГБ выглядят как 2 ГБ. Если не вышло,
# просто не называем число: лучше без цифры, чем с враньём.
$vram = 0
try {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($sub in Get-ChildItem $key -ErrorAction SilentlyContinue) {
        $v = (Get-ItemProperty $sub.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
        if ($v -and $v -gt $vram) { $vram = [int64]$v }
    }
} catch { }

if ($vram -gt 0) {
    Say ("  Видеопамять: {0:n0} ГБ" -f [math]::Round($vram / 1GB))
    if ($vram -lt 6GB) {
        Say ''
        Say '  Набор добавляет около 640 МБ занятой видеопамяти.' 'Yellow'
        Say '  При таком объёме её может не хватить, и игра начнёт дёргаться.' 'Yellow'
        Say '  Набор снимается тем же скриптом, так что попробовать можно.' 'Yellow'
    }
} else {
    Say '  Набор добавляет около 640 МБ занятой видеопамяти.'
    Say '  При 6 ГБ и меньше ставить не стоит, от 8 ГБ — спокойно.'
}
Say ''

# --- 5. Что уже стоит -----------------------------------------------------------------------
$installed = ''
$stampLines = ReadLines $StampFile
if ($stampLines.Count -gt 0) { $installed = $stampLines[0] }

# --- 6. Какой выпуск на GitHub --------------------------------------------------------------
Say '  Смотрю, что выложено...'
$api = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
try {
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'DeadAir-x64-HD' }
} catch {
    Fail @"
Не удалось связаться с GitHub: $($_.Exception.Message)

Проверьте подключение к сети. Если ошибка про защищённое соединение —
на Windows 7 нужно обновление, включающее TLS 1.2.
"@
}

$tag    = $rel.tag_name
$assets = @($rel.assets | Where-Object { $_.name -like 'DeadAir-x64-HD-*of*.tar.xz' } | Sort-Object name)
$sumsAsset = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
$listAsset = $rel.assets | Where-Object { $_.name -eq 'FILES.txt' }      | Select-Object -First 1

if ($assets.Count -eq 0) { Fail "В выпуске $tag нет частей набора. Похоже, выкладка ещё идёт — попробуйте позже." }
if (-not $sumsAsset)     { Fail "В выпуске $tag нет SHA256SUMS.txt — без него проверить загрузку нечем." }
if (-not $listAsset)     { Fail "В выпуске $tag нет FILES.txt — без него набор нельзя будет снять." }

$total = ($assets | Measure-Object -Property size -Sum).Sum
Say "  Выпуск: $tag — $($assets.Count) частей, $(Size $total)"
Say ''

# --- 7. Ставить, снимать или выйти ----------------------------------------------------------
$mode = 'install'
if ($installed) {
    if ($installed -eq $tag) {
        Say "  Набор уже стоит, версия та же ($tag)." 'Green'
    } else {
        Say "  Стоит версия $installed, доступна $tag." 'Yellow'
    }
    Say ''
    Say '    1 — переустановить набор'
    Say '    2 — снять набор и вернуть как было'
    Say '    3 — выйти'
    Say ''
    $choice = Read-Host '  Что делать'
    switch ($choice) {
        '1' { $mode = 'install' }
        '2' { $mode = 'remove' }
        default { Say ''; Say '  Ничего не делаю.'; exit 0 }
    }
} else {
    Say '  Набор ещё не стоит.'
    Say ''
    Say "  Будет скачано $(Size $total), после распаковки на диске 4.0 ГБ."
    Say ''
    $choice = Read-Host '  Ставить? (д/н)'
    if ($choice -notmatch '^[дdyтy]') { Say ''; Say '  Ничего не делаю.'; exit 0 }
}

if (-not (Test-Path $AppData)) { New-Item -ItemType Directory -Path $AppData -Force | Out-Null }

# --- СНЯТИЕ ---------------------------------------------------------------------------------
# Удаляем ровно то, что сами поставили, и ни файлом больше. Перечень взят не из выпуска, а из
# da_hd_files.txt, записанного при установке: если на GitHub с тех пор вышла другая версия
# набора с другим составом, перечень из неё удалил бы не то и оставил бы хвосты.
if ($mode -eq 'remove') {
    if (-not (Test-Path $FilesFile)) {
        Fail @"
Нет перечня установленных файлов ($FilesFile).

Без него сказать, какие текстуры принадлежат набору, а какие вашим другим
модам, нельзя — и удалять наугад скрипт не станет.
"@
    }
    Say ''
    Say '  Снимаю набор...'
    $list = ReadLines $FilesFile
    $gone = 0
    foreach ($rel_path in $list) {
        $p = Join-Path $Root $rel_path
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; $gone++ }
    }
    Say "  Удалено файлов: $gone"

    # Возвращаем то, что набор перекрыл.
    if (Test-Path $BackupDir) {
        $back = @(Get-ChildItem $BackupDir -Recurse -File)
        foreach ($b in $back) {
            $rel_path = $b.FullName.Substring($BackupDir.Length + 1)
            $dest = Join-Path $Root $rel_path
            $dir  = Split-Path -Parent $dest
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Move-Item $b.FullName $dest -Force
        }
        Say "  Возвращено из резерва: $($back.Count)"
        Remove-Item $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Пустые папки после удаления — мусор, но чужие не трогаем: убираем только те, что опустели.
    $texDir = Join-Path $Root 'gamedata\textures'
    if (Test-Path $texDir) {
        Get-ChildItem $texDir -Recurse -Directory |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem $_.FullName -Force)) { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            }
    }

    Remove-Item $StampFile, $PartsFile, $FilesFile -Force -ErrorAction SilentlyContinue
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
    Say ''
    Say '  Набор снят, всё вернулось как было.' 'Green'
    Say ''
    Read-Host 'Enter — выход'
    exit 0
}

# --- УСТАНОВКА ------------------------------------------------------------------------------
if (-not (Test-Path $Work)) { New-Item -ItemType Directory -Path $Work -Force | Out-Null }

# Версия сменилась — прошлые отметки о частях недействительны, состав мог поменяться.
if ($installed -and $installed -ne $tag) {
    Remove-Item $PartsFile -Force -ErrorAction SilentlyContinue
}

# Контрольные суммы.
Say '  Беру контрольные суммы...'
$sums = @{}
try {
    $raw = (New-Object Net.WebClient).DownloadString($sumsAsset.browser_download_url)
    foreach ($line in $raw -split "`n") {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') { $sums[$matches[2]] = $matches[1].ToLower() }
    }
} catch {
    Fail "Не удалось скачать SHA256SUMS.txt: $($_.Exception.Message)"
}

# Перечень файлов набора — понадобится и сейчас (найти перекрытия), и потом (для снятия).
Say '  Беру перечень файлов...'
try {
    $packFiles = @((New-Object Net.WebClient).DownloadString($listAsset.browser_download_url) -split "`r?`n" | Where-Object { $_.Trim() })
} catch {
    Fail "Не удалось скачать FILES.txt: $($_.Exception.Message)"
}

# Файлы самой сборки x64 — их набор перекрывать не должен. Если такое пересечение вдруг есть,
# мы обязаны об этом знать: наши правки важнее чужих текстур.
$ours = @{}
if (Test-Path $OurFiles) {
    foreach ($t in ReadLines $OurFiles) { $ours[$t.ToLower().Replace('/', '\')] = $true }
}
$clash = @($packFiles | Where-Object { $ours[$_.ToLower().Replace('/', '\')] })
if ($clash.Count -gt 0) {
    Say ''
    Say "  Внимание: набор перекрывает $($clash.Count) файлов самой сборки." 'Yellow'
    Say '  Они уйдут в резерв и вернутся при снятии набора.' 'Yellow'
    Say ''
}

# --- Загрузка с докачкой --------------------------------------------------------------------
# Обычный Invoke-WebRequest начинает с нуля при каждом запуске: оборвалась загрузка на 700-м
# мегабайте — качай их заново. Здесь запрашивается диапазон от уже скачанного байта, и поток
# дописывается в конец файла. Разорванное соединение стоит нам того, что не успело доехать,
# а не всей части.
function Get-Part($url, $dest, $expectSize) {
    $attempt = 0
    while ($true) {
        $have = 0
        if (Test-Path $dest) { $have = (Get-Item $dest).Length }
        if ($have -ge $expectSize) { return }

        $attempt++
        if ($attempt -gt 20) { throw "загрузка обрывается снова и снова, скачано $(Size $have) из $(Size $expectSize)" }
        # Часть уже начата — говорим об этом вслух. Иначе человек видит, что полоса стартует
        # с середины, и не понимает, доверять ей или нет.
        if ($have -gt 0 -and $attempt -eq 1) { Say "    продолжаю с $(Size $have) — заново качать не нужно" 'DarkGray' }

        try {
            $req = [Net.HttpWebRequest]::Create($url)
            $req.UserAgent = 'DeadAir-x64-HD'
            $req.Timeout   = 60000
            $req.ReadWriteTimeout = 60000
            if ($have -gt 0) { $req.AddRange([int64]$have) }

            $resp = $req.GetResponse()
            # Сервер вправе не понять запрос диапазона и прислать файл целиком. Тогда начинаем
            # заново, иначе получим склейку из двух кусков — она пройдёт по размеру и провалит
            # проверку суммы, а причина будет неочевидной.
            if ($have -gt 0 -and [int]$resp.StatusCode -ne 206) { $have = 0 }

            $fmode = if ($have -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
            $in  = $resp.GetResponseStream()
            $out = New-Object IO.FileStream($dest, $fmode, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $started   = Get-Date
            $fromStart = [int64]$have
            try {
                $buf  = New-Object byte[] 262144
                $done = [int64]$have
                # ⛔ Полоса рисовалась раз в N прочитанных кусков — то есть раз в 10 МБ. На канале
                # в 60 КБ/с это три минуты пустого экрана, и человек решает, что всё повисло.
                # Считать надо ВРЕМЯ, а не байты: на быстром канале строка не мельтешит,
                # на медленном всё равно обновляется. Первую строку рисуем сразу.
                $lastDraw = (Get-Date).AddSeconds(-10)
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $out.Write($buf, 0, $n)
                    $done += $n
                    $now = Get-Date
                    if (($now - $lastDraw).TotalMilliseconds -ge 400) {
                        $lastDraw = $now
                        $sec   = ($now - $started).TotalSeconds
                        $speed = if ($sec -gt 0) { ($done - $fromStart) / $sec } else { 0 }
                        $left  = if ($speed -gt 0) { [int](($expectSize - $done) / $speed) } else { 0 }
                        $line = '    {0,3:n0}%  {1} из {2}   {3}   осталось ~{4}' -f `
                            (($done * 100) / $expectSize), (Size $done), (Size $expectSize), (Speed $speed), (Left $left)
                        Write-Host ("`r" + $line.PadRight(66)) -NoNewline
                    }
                }
            } finally {
                $out.Close(); $in.Close(); $resp.Close()
            }
            Write-Host ("`r" + ('    готово: ' + (Size $expectSize)).PadRight(66))
        } catch {
            $now = 0
            if (Test-Path $dest) { $now = (Get-Item $dest).Length }
            if ($now -ge $expectSize) { return }

            # Повторять имеет смысл ТОЛЬКО сетевую ошибку. Ошибку в самом установщике двадцать
            # повторов лишь спрячут за ложным «связь оборвалась», и человек полезет чинить
            # интернет, с которым всё в порядке.
            if ($_.Exception -isnot [Net.WebException]) { throw }

            Say ''
            Say "    связь оборвалась на $(Size $now) — продолжаю с этого места (попытка $attempt)" 'DarkYellow'
            Start-Sleep -Seconds 3
        }
    }
}

# Что набор поставил в прошлый раз. Нужно, чтобы при переустановке не спутать его собственные
# файлы с файлами игры (см. ниже, в разборе резерва).
$prevOwned = @{}
if (Test-Path $FilesFile) {
    foreach ($t in ReadLines $FilesFile) { $prevOwned[$t.ToLower().Replace('/', '\')] = $true }
}

# Какие части уже поставлены.
$done = @{}
if (Test-Path $PartsFile) {
    foreach ($t in ReadLines $PartsFile) { $done[$t] = $true }
}

$n = 0
foreach ($a in $assets) {
    $n++
    if ($done[$a.name]) {
        Say "  [$n/$($assets.Count)] $($a.name) — уже поставлена, пропускаю" 'DarkGray'
        continue
    }

    Say ''
    Say "  [$n/$($assets.Count)] $($a.name) — $(Size $a.size)"

    $dest = Join-Path $Work $a.name
    try {
        Get-Part $a.browser_download_url $dest $a.size
    } catch {
        Fail "Не удалось скачать $($a.name): $($_.Exception.Message)"
    }

    # Проверка суммы. Битая часть — это не «наверное, обойдётся»: половина текстур в наборе
    # прочитается, а на второй половине игра свалится в загрузке, и виноват будет якобы движок.
    Say '    проверяю целостность...'
    $want = $sums[$a.name]
    if (-not $want) { Fail "В SHA256SUMS.txt нет строки для $($a.name)." }
    $got = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        Fail @"
Часть $($a.name) скачалась повреждённой.

Файл удалён — запустите скрипт ещё раз, он скачает её заново.
"@
    }

    # Что эта часть перекроет — уносим в резерв. Именно ДО распаковки: после неё оригинала
    # уже нет, и вернуть при снятии будет нечего.
    $inPart = @(& $Tar -tf $dest 2>$null | Where-Object { $_ -and $_ -notmatch '/$' })
    $saved = 0
    foreach ($f in $inPart) {
        $rel_path = $f.Replace('/', '\')
        # Файл, который уже принадлежит набору с прошлой установки, оригиналом НЕ является:
        # унеси мы его в резерв — при снятии он вернулся бы на место как «файл игры», и набор
        # стал бы неснимаемым. В резерв идёт только то, что набору не принадлежит.
        if ($prevOwned[$rel_path.ToLower()]) { continue }
        $src = Join-Path $Root $rel_path
        if (Test-Path $src) {
            $bak = Join-Path $BackupDir $rel_path
            if (-not (Test-Path $bak)) {
                $dir = Split-Path -Parent $bak
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Move-Item $src $bak -Force
                $saved++
            }
        }
    }
    if ($saved -gt 0) { Say "    в резерв убрано файлов: $saved" }

    Say '    распаковываю...'
    Push-Location $Root
    try {
        & $Tar -xf $dest
        if ($LASTEXITCODE -ne 0) { throw "tar вернул код $LASTEXITCODE" }
    } catch {
        Pop-Location
        Fail "Не удалось распаковать $($a.name): $($_.Exception.Message)"
    }
    Pop-Location

    # Часть встала — отмечаем и сносим загрузку, чтобы не занимала место. Отметка ставится
    # ПОСЛЕ распаковки: оборвись питание в середине, при следующем запуске часть переставится
    # целиком, а не окажется наполовину поставленной и помеченной как готовая.
    AppendText $PartsFile $a.name
    Remove-Item $dest -Force -ErrorAction SilentlyContinue
    Say "    готово" 'Green'
}

# --- Отметки --------------------------------------------------------------------------------
WriteText $FilesFile ($packFiles -join "`r`n")
WriteText $StampFile $tag
Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue

Say ''
Say '  ------------------------------------------' 'Cyan'
Say "  HD-текстуры поставлены. Версия набора: $tag" 'Green'
Say ''
Say '  Набор снимается этим же скриптом: запустите его снова'
Say '  и выберите «снять набор».'
Say ''
Say '  Автор набора — Akinaro, https://www.moddb.com/mods/stalker-two-k'
Say ''
Read-Host 'Enter — выход'
