#!/usr/bin/env ruby
# encoding: utf-8
#
# Сторож торгов: следит за разделами недвижимости и транспорта на e-auction.by и ipmtorgi.by
# и шлёт в Telegram карточку по каждому новому лоту: фото, цена, дата окончания приёма заявок.
#
#   ruby tgbot.rb --init    первый запуск: запомнить текущие лоты и НИЧЕГО не слать
#   ruby tgbot.rb           обычный запуск: прислать только новые
#   ruby tgbot.rb --test    проверить связь с Telegram
#
# Токен НЕ хранится в коде. Он читается из ~/.torgi/token (chmod 600) или из ENV['TG_TOKEN'].
require 'json'
require 'fileutils'
require 'shellwords'
require 'time'
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Площадки печатают минское время без указания зоны, а сервер обычно живёт в UTC.
# Прибиваем зону, чтобы дедлайны не уезжали на три часа.
ENV['TZ'] = 'Europe/Minsk'

HOME     = File.expand_path(ENV['TORGI_HOME'] || '~/.torgi')
SEEN     = File.join(HOME, 'seen.json')
LOG      = File.join(HOME, 'bot.log')
LOCK     = File.join(HOME, 'lock')
TMPIMG   = File.join(HOME, 'photo.tmp')
UA       = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
MAX_SEND = (ENV['MAX_SEND'] || 25).to_i   # предохранитель от лавины сообщений
FileUtils.mkdir_p(HOME)

SECTIONS = [
  ['e-auction.by', 'Недвижимость',           'https://e-auction.by/nedvizhimost/'],
  ['e-auction.by', 'Легковые авто',          'https://e-auction.by/legkovye_avtomobili/'],
  ['e-auction.by', 'Грузовые и автобусы',    'https://e-auction.by/gruzovaya_tekhnika_i_avtobusy/'],
  ['ipmtorgi.by',  'Недвижимость',           'https://ipmtorgi.by/auctions/nedvizhimost/'],
  ['ipmtorgi.by',  'Транспорт и спецтехника','https://ipmtorgi.by/auctions/transport-i-spetstekhnika/']
].freeze

def log(msg)
  line = "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}  #{msg}"
  warn line
  File.open(LOG, 'a') { |f| f.puts line }
rescue StandardError
  nil
end

def token
  @token ||= (ENV['TG_TOKEN'] || (File.exist?(File.join(HOME, 'token')) ? File.read(File.join(HOME, 'token')).strip : '')).to_s
  abort("нет токена: положите его в #{File.join(HOME, 'token')} или задайте TG_TOKEN") if @token.empty?
  @token
end

def api(method, args = [])
  cmd = ['curl', '-sS', '-m', '60', '--retry', '2', '--retry-delay', '2',
         "https://api.telegram.org/bot#{token}/#{method}"] + args
  out = ''
  IO.popen(cmd, 'rb', err: %i[child out]) { |io| out = io.read.to_s }
  out.force_encoding('UTF-8')
  JSON.parse(out)
rescue JSON::ParserError
  log("ответ Telegram не разобран (#{out.bytesize} б): #{out[0, 200].inspect}")
  { 'ok' => false, 'description' => 'некорректный ответ Telegram' }
rescue StandardError => e
  { 'ok' => false, 'description' => e.message }
end

# chat_id: берём сохранённый, иначе достаём из последнего сообщения боту
def chat_id
  return ENV['TG_CHAT_ID'].strip if ENV['TG_CHAT_ID'].to_s.strip != ''
  f = File.join(HOME, 'chat_id')
  return File.read(f).strip if File.exist?(f) && !File.read(f).strip.empty?
  r = api('getUpdates')
  ids = (r['result'] || []).map { |u| u.dig('message', 'chat', 'id') }.compact.uniq
  if ids.empty?
    abort("не знаю, кому слать. Напишите боту в Telegram любое сообщение (например /start) и запустите ещё раз")
  end
  File.write(f, ids.last.to_s)
  log("chat_id определён: #{ids.last}")
  ids.last.to_s
end

def fetch(url)
  2.times do
    out = IO.popen(['curl', '-sS', '-L', '-m', '40', '-A', UA, url], err: File::NULL, &:read)
    out = out.to_s.force_encoding('UTF-8')
    return out if out.size > 1500
    sleep 2
  end
  nil
end

def clean(s)
  s.to_s.gsub(/<[^>]*>/, ' ').gsub('&nbsp;', ' ').gsub('&quot;', '"')
   .gsub('&laquo;', '«').gsub('&raquo;', '»').gsub('&amp;', '&').gsub(/\s+/, ' ').strip
end

# ---------- разбор листингов ----------
def parse_ea(html, section)
  html.split('class="product-item column').drop(1).map do |ch|
    ch = ch[0, 6000]
    href = ch[/href="(\/[^"]+)"/, 1]
    art  = ch[/class="product_art"[^>]*>\s*([0-9.]+)/m, 1]
    next nil unless href && art
    img = ch[/<img src="(\/upload\/[^"]+)"/, 1]
    req = ch[/data-endrequest="(\d+)"/, 1].to_i
    { id: "e-auction.by|#{art}", platform: 'e-auction.by', section: section,
      name: clean(ch[/class="text-header">\s*([^<]*)/m, 1]),
      price: ch[/data-cur="BYN" data-value="([0-9.]+)"/, 1].to_f,
      deadline: req.positive? ? Time.at(req) : nil,
      photo: img ? 'https://e-auction.by' + img : nil,
      url: 'https://e-auction.by' + href }
  end.compact
end

def parse_ipm(html, section)
  html.split('class="c-list__item"').drop(1).map do |ch|
    ch = ch[0, 4000]
    url = ch[/href="(https:\/\/ipmtorgi\.by\/auctions\/[^"]+)"/, 1]
    next nil unless url
    d   = ch[/c-list__item-info__date"><span>[^<]*<\/span>\s*<span>\s*([^<]*)<\/span>/m, 1].to_s
    dt  = d[/(\d{2})\.(\d{2})\.(\d{4})/] ? Time.local($3.to_i, $2.to_i, $1.to_i,
            (d[/\|\s*(\d{2}):/, 1] || '0').to_i, (d[/\|\s*\d{2}:(\d{2})/, 1] || '0').to_i) : nil
    img = ch[/background-image: url\('(\/upload\/[^']+)'\)/, 1]
    { id: "ipmtorgi.by|#{url.split('/').last}", platform: 'ipmtorgi.by', section: section,
      name: clean(ch[/c-list__item-info__name">\s*([^<]*)/m, 1]),
      price: clean(ch[/Начальная цена:<\/span>\s*<span>\s*([0-9 .,]+)\s*BYN/m, 1]).gsub(/[^0-9.]/, '').to_f,
      deadline: dt, photo: img ? 'https://ipmtorgi.by' + img : nil, url: url }
  end.compact
end

def collect
  lots = []
  SECTIONS.each do |platform, section, url|
    html = fetch(url)
    if html.nil?
      log("не ответил: #{url}")
      next
    end
    got = platform == 'e-auction.by' ? parse_ea(html, section) : parse_ipm(html, section)
    log("#{platform} · #{section}: #{got.size}")
    lots.concat(got)
    sleep 1
  end
  lots
end

# ---------- отправка ----------
def money(n)
  return 'цена не указана' if n.to_f <= 0
  "#{n.round.to_s.reverse.scan(/\d{1,3}/).join(' ').reverse} BYN"
end

def send_lot(lot, cid)
  caption = "<b>#{money(lot[:price])}</b>\n" \
            "Заявки до #{lot[:deadline] ? lot[:deadline].strftime('%d.%m.%Y %H:%M') : '—'}\n" \
            "<a href=\"#{lot[:url]}\">#{lot[:platform]} · #{lot[:section]}</a>"
  if lot[:photo]
    File.delete(TMPIMG) if File.exist?(TMPIMG)
    system('curl', '-sS', '-L', '-m', '40', '-A', UA, '-o', TMPIMG, lot[:photo],
           out: File::NULL, err: File::NULL)
  end
  # --form-string, а не -F: значение подписи начинается с "<b>", а curl считает
  # начальные "<" и "@" ссылкой на файл и пытается его открыть.
  r = if lot[:photo] && File.exist?(TMPIMG) && File.size(TMPIMG) > 1000
        api('sendPhoto', ['--form-string', "chat_id=#{cid}", '-F', "photo=@#{TMPIMG}",
                          '--form-string', "caption=#{caption}",
                          '--form-string', 'parse_mode=HTML'])
      else
        api('sendMessage', ['--form-string', "chat_id=#{cid}", '--form-string', "text=#{caption}",
                            '--form-string', 'parse_mode=HTML'])
      end
  # если фото не приняли — пробуем хотя бы текстом, чтобы лот не потерялся
  unless r['ok']
    log("фото не ушло (#{r['description']}), пробую текстом: #{lot[:name][0, 40]}")
    r = api('sendMessage', ['--form-string', "chat_id=#{cid}", '--form-string', "text=#{caption}",
                            '--form-string', 'parse_mode=HTML'])
  end
  log("не отправлено (#{r['description']}): #{lot[:name][0, 40]}") unless r['ok']
  r['ok']
end

# ---------- запуск ----------
if File.exist?(LOCK) && (Time.now - File.mtime(LOCK)) < 600
  log('предыдущий запуск ещё идёт — выхожу')
  exit 0
end
File.write(LOCK, Process.pid.to_s)

begin
  mode = ARGV[0]

  if mode == '--test'
    me = api('getMe')
    abort("Telegram не принял токен: #{me['description']}") unless me['ok']
    cid = chat_id
    api('sendMessage', ['--form-string', "chat_id=#{cid}",
                        '--form-string', 'text=Сторож торгов на связи. Слежу за недвижимостью и транспортом.'])
    log("связь есть: @#{me.dig('result', 'username')}, chat_id #{cid}")
    exit 0
  end

  seen = File.exist?(SEEN) ? JSON.parse(File.read(SEEN)) : {}
  lots = collect
  abort('ни одна площадка не ответила') if lots.empty?

  if mode == '--dry'
    lots.first(6).each do |l|
      puts "— #{money(l[:price])} | заявки до #{l[:deadline] ? l[:deadline].strftime('%d.%m.%Y %H:%M') : 'НЕТ'}"
      puts "  фото: #{l[:photo] ? 'есть' : 'НЕТ'}  #{l[:section]}  #{l[:name][0, 46]}"
    end
    bad = lots.count { |l| l[:deadline].nil? } + lots.count { |l| l[:photo].nil? } + lots.count { |l| l[:price].to_f <= 0 }
    puts "всего #{lots.size}; без даты #{lots.count { |l| l[:deadline].nil? }}, " \
         "без фото #{lots.count { |l| l[:photo].nil? }}, без цены #{lots.count { |l| l[:price].to_f <= 0 }}"
    exit(bad.zero? ? 0 : 0)
  end

  fresh = lots.reject { |l| seen.key?(l[:id]) }
  log("получено #{lots.size}, новых #{fresh.size}")

  if mode == '--init'
    lots.each { |l| seen[l[:id]] = Time.now.to_i }
    File.write(SEEN, JSON.generate(seen))
    log("инициализация: запомнил #{lots.size} лотов, ничего не отправлял")
    exit 0
  end

  if fresh.size > MAX_SEND
    log("новых #{fresh.size} — это больше предохранителя #{MAX_SEND}; отправлю #{MAX_SEND}, остальные помечу прочитанными")
  end

  # Счётчик неудач: лот, который не удалось отправить, пробуем ещё дважды
  # в следующих циклах, а не теряем молча.
  fails_path = File.join(HOME, 'fails.json')
  fails = File.exist?(fails_path) ? JSON.parse(File.read(fails_path)) : {}

  cid = chat_id
  sent = 0
  fresh.sort_by { |l| l[:deadline] || Time.now }.each do |l|
    if sent >= MAX_SEND
      seen[l[:id]] = Time.now.to_i        # осознанно пропускаем: сработал предохранитель
      next
    end
    if send_lot(l, cid)
      sent += 1
      seen[l[:id]] = Time.now.to_i
      fails.delete(l[:id])
    else
      fails[l[:id]] = fails[l[:id]].to_i + 1
      if fails[l[:id]] >= 3
        log("сдаюсь после 3 попыток: #{l[:name][0, 50]}")
        seen[l[:id]] = Time.now.to_i
        fails.delete(l[:id])
      end
    end
    sleep 1.2
  end
  File.write(fails_path, JSON.generate(fails))

  # чистим память старше 120 дней, чтобы файл не рос вечно
  cutoff = Time.now.to_i - 120 * 86_400
  seen.reject! { |_, t| t.to_i < cutoff }
  File.write(SEEN, JSON.generate(seen))
  log("отправлено #{sent}, в памяти #{seen.size}")
ensure
  File.delete(LOCK) if File.exist?(LOCK)
end
