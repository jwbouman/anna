<?php
// prices.php

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');

$marketstackKey = getenv('5698db8e1cb4ca78fa2aebadf9e0afd1') ?: 'zet-hier-tijdelijk-je-key';

$symbol = $_GET['symbol'] ?? '';
$days = (int)($_GET['days'] ?? 60);

if ($symbol === '' || $days < 1 || $days > 90) {
    http_response_code(400);
    echo json_encode(['error' => 'Invalid symbol or days']);
    exit;
}

$endDate = new DateTimeImmutable('today');
$startDate = $endDate->modify('-' . max($days * 3, 90) . ' days');

$query = http_build_query([
    'access_key' => $marketstackKey,
    'symbols' => strtoupper(trim($symbol)),
    'date_from' => $startDate->format('Y-m-d'),
    'date_to' => $endDate->format('Y-m-d'),
    'sort' => 'ASC',
    'limit' => max($days * 3, 100),
]);

$url = 'https://api.marketstack.com/v2/eod?' . $query;

$response = file_get_contents($url);

if ($response === false) {
    http_response_code(502);
    echo json_encode(['error' => 'Marketstack request failed']);
    exit;
}

echo $response;
