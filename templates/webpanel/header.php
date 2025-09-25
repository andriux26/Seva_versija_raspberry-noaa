<?php
  // Debug (galima isjungti prod’e)
  ini_set('display_errors', 1);
  ini_set('display_startup_errors', 1);
  error_reporting(E_ALL);

  date_default_timezone_set('Europe/Vilnius');

  // Koks failas atidarytas (pvz., index.php / index1.php / passes.php)
  $page = basename($_SERVER['PHP_SELF']);

  // Konfigas + kalba
  $configs = include('Config.php'); // turi grazinti objekta su ->lang
  $lang = isset($configs->lang) ? $configs->lang : 'en';
  include_once('language/' . $lang . '.php'); // $lang[...] masyvas

  // Puslapio pavadinimas (pasikeisk pagal poreiki)
  if (!isset($PageTitle)) { $PageTitle = ""; }
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <link rel="stylesheet" type="text/css" href="style.css">
  <title><?= htmlspecialchars($PageTitle, ENT_QUOTES, 'UTF-8') ?></title>
</head>
<body>

<!-- NAV -->
<div class="topnav">
  <a class="<?= $page==='passes.php' ? 'active' : '' ?>" href="passes.php">
    <?= htmlspecialchars($lang['passes'] ?? 'Passes', ENT_QUOTES, 'UTF-8') ?>
  </a>

  <!-- Images: index.php (ir, jei turi, detail.php su nuotraukomis) -->
  <a class="<?= in_array($page, ['index.php','detail.php'], true) ? 'active' : '' ?>" href="index.php">
    <?= htmlspecialchars($lang['images'] ?? 'Images', ENT_QUOTES, 'UTF-8') ?>
  </a>

  <!-- Audio: index1.php -->
  <a class="<?= $page==='index1.php' ? 'active' : '' ?>" href="index1.php">
    <?= htmlspecialchars($lang['audio'] ?? 'Audio', ENT_QUOTES, 'UTF-8') ?>
  </a>
</div>

<!-- TURINYS -->
<div class="container">
  <!-- vvv CIA tavo turinys siam puslapiui vvv -->
  <!-- Pvz., index.php rodys nuotraukas; index1.php – audio; passes.php – praskridimus. -->
  <!-- Palikau tuscia; idek savo esama HTML/PHP turini. -->
  <h2 style="margin:1rem 0;">
    <?= htmlspecialchars($PageTitle, ENT_QUOTES, 'UTF-8') ?>
  </h2>
  <!-- ^^^ CIA tavo turinys siam puslapiui ^^^ -->
</div>

</body>
</html>


