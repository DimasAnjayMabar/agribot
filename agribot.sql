-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Waktu pembuatan: 25 Mar 2026 pada 05.48
-- Versi server: 10.4.32-MariaDB
-- Versi PHP: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `agribot`
--

-- --------------------------------------------------------

--
-- Struktur dari tabel `alembic_version`
--

CREATE TABLE `alembic_version` (
  `version_num` varchar(32) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data untuk tabel `alembic_version`
--

INSERT INTO `alembic_version` (`version_num`) VALUES
('cd94a715ea0d');

-- --------------------------------------------------------

--
-- Struktur dari tabel `chats`
--

CREATE TABLE `chats` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `title` text NOT NULL,
  `created_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data untuk tabel `chats`
--

INSERT INTO `chats` (`id`, `user_id`, `title`, `created_at`) VALUES
(5, 6, 'halo', '2026-03-24 03:59:15'),
(8, 6, 'jelaskan tentang busuk cincin bakteri...', '2026-03-24 04:46:41'),
(9, 6, 'jelaskan tentang busuk lunak bakteri', '2026-03-24 04:55:45');

-- --------------------------------------------------------

--
-- Struktur dari tabel `chat_details`
--

CREATE TABLE `chat_details` (
  `id` int(11) NOT NULL,
  `chat_id` int(11) NOT NULL,
  `question` text NOT NULL,
  `response` text NOT NULL,
  `created_at` datetime DEFAULT NULL,
  `processing_status` varchar(10) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data untuk tabel `chat_details`
--

INSERT INTO `chat_details` (`id`, `chat_id`, `question`, `response`, `created_at`, `processing_status`) VALUES
(4, 5, 'halo', 'Halo! Ada yang bisa saya bantu hari ini?', '2026-03-24 03:59:19', 'done'),
(5, 5, 'apa kabar?', 'Alhamdulillah baik, terima kasih sudah bertanya! Bagaimana dengan Anda?', '2026-03-24 03:59:44', 'done'),
(6, 5, 'baik', 'Senang mendengarnya! Ada yang bisa saya bantu?', '2026-03-24 03:59:52', 'done'),
(7, 5, 'jelaskan tentang busuk cincin bakteri dong', '**Busuk Cincin Bakteri (Bacterial Ring Rot) pada Kentang**\n\n**1. Penyebab**  \n- Disebabkan oleh bakteri *Clavibacter michiganensis* (juga disebut *Clavibacter sepedonicus*).  \n- Bakteri ini merupakan Gram‑positif, berbentuk batang pendek, tidak bergerak, bersifat aerobik (dapat tumbuh perlahan pada kondisi anaerob).\n\n**2. Suhu pertumbuhan optimal**  \n- 20 – 23 °C (Davis et al., 1984; Osdaghi et al., 2022).\n\n**3. Cara penularan**  \n- **Bibit terinfeksi**: menanam umbi atau bibit yang sudah terkontaminasi akan menghasilkan rumpun yang terinfeksi.  \n- **Alat pertanian**: penggunaan pisau atau peralatan yang sama untuk memotong umbi sakit dan umbi sehat dapat menyebarkan bakteri.  \n- **Kontak fisik antar rumpun**: pada kepadatan tanam yang tinggi dan curah hujan tinggi, bakteri dapat berpindah ke rumpun berdekatan melalui kontak langsung.  \n- **Tidak menular melalui tanah** secara signifikan, namun dapat bertahan singkat di dalam tanah.\n\n**4. Ketahanan bakteri**  \n- **Batang kering tanaman**: dapat bertahan hingga **5 tahun**.  \n- **Permukaan kering** (plastik goni atau kayu lapis): bertahan **2 tahun**.  \n- **Tanah**: bertahan hanya dalam waktu singkat.  \n- Untuk memusnahkan bakteri, dapat dilakukan **pembajakan dan penimbunan ke dalam tanah** (Sastrahidayat, 2011).\n\n**5. Gejala pada umbi**  \n- **Permukaan luar**: retakan dan bercak gelap tepat di bawah periderm; warna berubah menjadi coklat kemerahan.  \n- **Saat dipotong membujur**: muncul lingkaran coklat, berlubang; cairan berwarna krem‑keju atau “eksudat susu” keluar dari cincin vaskular.  \n- **Tekstur**: pada infeksi parah, korteks dapat terpisah dan seluruh umbi membusuk.  \n- **Gejala pada tanaman**: layu daun bagian bawah, daun menguning, tepi daun menggulung, batang bagian bawah mengeluarkan cairan putih menyerupai susu ketika dipotong.\n\n**6. Variasi gejala menurut varietas**  \n- Pada beberapa varietas, umbi dapat menunjukkan warna kuning pucat sampai coklat muda tanpa lendir (Tarigan, 2017).\n\n**7. Pengendalian / Manajemen**  \n- **Bibit bersertifikat**: menanam umbi sehat dan terstandarisasi.  \n- **Sterilisasi alat**: menggunakan merkuri klorida (HgCl₂) atau bahan kimia lain (mis. cresol 3 % + sabun 0.1‑1 %).  \n- **Sanitasi gudang**: mensterilkan wadah, lantai, dan tangan yang bersentuhan dengan umbi.  \n- **Penghilangan tanaman terinfeksi**: membuang atau memusnahkan tanaman yang terjangkit pada saat panen.  \n- **Rotasi tanaman**: menanam tanaman non‑kentang (mis. bit gula) dan membiarkan lahan tidak ditanami kentang setidaknya satu tahun.  \n- **Pengelolaan sisa tanaman**: menggali sisa-sisa kentang, membuang karung/tas, serta memusnahkan sisa umbi dengan pembekuan atau penguburan.  \n- **Perbanyakan strain**: penggunaan strain yang tidak patogen untuk kompetisi (sebagian disebut dalam literatur, meski detail tidak diberikan).  \n\n**Ringkasan**  \nBusuk cincin bakteri adalah penyakit menular yang disebabkan oleh *Clavibacter michiganensis*, tumbuh optimal pada suhu 20‑23 °C, dan menyebar terutama melalui bibit terinfeksi, peralatan pertanian, serta kontak antar rumpun pada kepadatan tinggi. Bakteri dapat bertahan lama pada bahan kering, tetapi tidak lama di tanah. Gejalanya meliputi retakan, perubahan warna, dan eksudat berwarna krem‑keju pada umbi, serta layu pada bagian atas tanaman. Pengendalian meliputi penggunaan bibit bersertifikat, sterilisasi peralatan, sanitasi gudang, pembuangan tanaman terinfeksi, rotasi tanaman, dan pemusnahan sisa tanaman.', '2026-03-24 04:06:22', 'done'),
(8, 8, 'jelaskan tentang busuk cincin bakteri dong', '**Busuk Cincin Bakteri (Bacterial Ring Rot) pada Kentang**\n\n**1. Penyebab**  \n- Disebabkan oleh bakteri *Clavibacter michiganensis* (juga disebut *Clavibacter sepedonicus*).  \n- Bakteri ini merupakan Gram‑positif, berbentuk batang pendek, tidak bergerak, bersifat aerobik (dapat tumbuh lambat dalam kondisi anaerob).\n\n**2. Suhu pertumbuhan optimal**  \n- 20 – 23 °C (Davis et al., 1984; Osdaghi et al., 2022).\n\n**3. Cara penularan**  \n- **Bibit terinfeksi**: menanam umbi atau bibit yang sudah mengandung bakteri akan menghasilkan rumpun terinfeksi.  \n- **Alat pertanian**: penggunaan pisau atau peralatan yang sama untuk memotong umbi sakit dan umbi sehat dapat menularkan bakteri.  \n- **Kontak antar‑rumpun**: pada kepadatan tanam yang tinggi dan curah hujan tinggi, bakteri dapat berpindah ke rumpun berdekatan melalui kontak fisik.  \n- **Tidak menular melalui tanah** secara langsung, namun dapat berpindah lewat sisa tanaman atau bahan organik yang bersentuhan.\n\n**4. Ketahanan bakteri di lingkungan**  \n- **Batang kering tanaman**: dapat bertahan hingga **5 tahun**.  \n- **Permukaan kering (plastik goni atau kayu lapis)**: bertahan **2 tahun**.  \n- **Di dalam tanah**: bertahan hanya dalam waktu singkat.  \n- Untuk memusnahkan bakteri, dapat dilakukan **pembajakan dan penimbunan ke dalam tanah** (Sastrahidayat, 2011).\n\n**5. Gejala pada umbi**  \n- **Permukaan luar**: retakan dan bercak gelap tepat di bawah periderm; warna berubah menjadi coklat kemerahan.  \n- **Saat dipotong membujur**: muncul lingkaran coklat, berlubang; cairan berwarna krem‑keju atau “eksudat susu” keluar dari cincin vaskular.  \n- **Jika diperas**: bahan seperti keju mengalir keluar.  \n- Pada infeksi parah, korteks dapat terpisah dan seluruh umbi membusuk.  \n- **Gejala pada tanaman**: layu daun bagian bawah, daun menguning, tepi daun menggulung, batang bagian bawah mengeluarkan cairan putih menyerupai susu.\n\n**6. Variasi gejala menurut varietas**  \n- Beberapa varietas menunjukkan warna kuning pucat sampai coklat muda pada umbi yang dibelah melalui ujung stolon, tanpa lendir (Tarigan, 2017).\n\n**7. Pengendalian / Upaya Pencegahan**  \n- **Pemilihan bibit unggul**: menanam umbi bersertifikat dan sehat.  \n- **Sterilisasi peralatan**: menggunakan merkuri klorida (HgCl₂) atau bahan kimia lain (mis. cresol 3 % + sabun 0.1‑1 %).  \n- **Pemusnahan tanaman terinfeksi**: membuang atau menghancurkan tanaman yang sakit pada saat panen.  \n- **Sanitasi gudang**: mensterilkan gudang, wadah, dan permukaan yang bersentuhan dengan umbi.  \n- **Rotasi tanaman**: menanam tanaman selain kentang (mis. bit gula) dan membiarkan lahan tidak ditanami kentang setidaknya satu tahun.  \n- **Pengelolaan sisa tanaman**: menggali sisa-sisa kentang, membuang karung/tas, serta memusnahkan sisa umbi dengan pembekuan atau penguburan.  \n- **Perbanyakan strain**: penggunaan strain yang tidak patogen untuk kompetisi biologi (sebagian disebut dalam literatur).  \n\n**Ringkasan**  \nBusuk cincin bakteri adalah penyakit menular pada umbi kentang yang disebabkan oleh *Clavibacter michiganensis*. Penyakit ini mudah menyebar melalui bibit terinfeksi, peralatan pertanian, dan kontak antar‑rumpun pada kondisi lembab serta kepadatan tinggi. Bakteri dapat bertahan lama pada bahan kering, tetapi tidak lama di tanah. Gejalanya meliputi retakan, perubahan warna, dan eksudat krem‑keju pada umbi, serta layu pada bagian tanaman. Pengendalian utama meliputi penggunaan bibit bersertifikat, sterilisasi peralatan, sanitasi gudang, rotasi tanaman, serta pemusnahan sisa tanaman dan umbi terinfeksi.', '2026-03-24 04:46:41', 'done'),
(9, 9, 'jelaskan tentang busuk lunak bakteri', '**Busuk Lunak Bakteri (Bacterial Soft Rot) pada Kentang**\n\n**Penyebab**  \n- Disebabkan oleh bakteri *Erwinia carotovora* (juga disebut *Erwinia chrysanthemi* pada beberapa literatur).  \n- Merupakan bakteri Gram‑negatif berbentuk batang, berflagel, dapat hidup secara aerob maupun anaerob.\n\n**Karakteristik bakteri**  \n- Hidup optimal pada suhu hangat; beberapa strain hanya dapat bertahan di lingkungan yang hangat.  \n- Memiliki kemampuan untuk menghasilkan enzim pektinase yang memecah jaringan tanaman, sehingga menyebabkan jaringan umbi menjadi lunak dan basah.  \n\n**Faktor penyebaran**  \n- Bakteri dapat terbawa oleh tanah dan menyebar dengan sangat cepat.  \n- Faktor utama yang mempercepat penyebaran adalah **kelembaban udara yang tinggi**.  \n- Karena bakteri ini dapat hidup di tanah, pengendalian kimiawi menjadi sulit.\n\n**Gejala pada umbi kentang**  \n- Terjadi pembusukan lunak pada umbi yang mengubah fisik, fisiologi, dan kimia jaringan.  \n- Pada umbi yang terinfeksi terlihat **area busuk berwarna coklat kemerahan** yang dapat berubah menjadi cairan berwarna krem‑keju atau lendir ketika umbi dipotong atau diperas.  \n- Gejala dapat muncul cepat setelah infeksi, terutama pada kondisi lembab.\n\n**Pengendalian**  \n- **Agen hayati** terbukti efektif: kombinasi *Bacillus subtilis* dan *Pseudomonas fluorescens* dapat mengendalikan busuk lunak umbi kentang yang disebabkan oleh *Erwinia carotovora* (Javandira et al., 2013).  \n- Karena kelembaban tinggi merupakan faktor utama, pengelolaan kelembaban lingkungan (misalnya ventilasi yang baik, pengeringan lahan setelah hujan) juga penting untuk menurunkan risiko penyebaran.  \n\n**Ringkasan**  \nBusuk lunak bakteri pada kentang adalah penyakit yang disebabkan oleh *Erwinia carotovora*, bakteri Gram‑negatif yang menghasilkan enzim pemecah jaringan. Penyakit ini menyebar cepat melalui tanah dan terutama dipercepat oleh kelembaban udara tinggi. Gejalanya berupa pembusukan lunak, perubahan warna, dan eksudat berwarna krem‑keju pada umbi. Pengendalian yang paling efektif, menurut konteks yang ada, adalah penggunaan agen hayati seperti *Bacillus subtilis* dan *Pseudomonas fluorescens* serta pengaturan kelembaban lingkungan.', '2026-03-24 04:55:45', 'done');

-- --------------------------------------------------------

--
-- Struktur dari tabel `otp_change_email`
--

CREATE TABLE `otp_change_email` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `otp` varchar(6) NOT NULL,
  `otp_expires_at` datetime NOT NULL,
  `is_used` tinyint(1) NOT NULL,
  `is_invalidated` tinyint(1) NOT NULL,
  `request_count_today` int(11) NOT NULL,
  `change_token` varchar(255) DEFAULT NULL,
  `change_token_expires_at` datetime DEFAULT NULL,
  `created_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Struktur dari tabel `otp_registrasi`
--

CREATE TABLE `otp_registrasi` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `otp` varchar(6) NOT NULL,
  `otp_expires_at` datetime NOT NULL,
  `is_used` tinyint(1) NOT NULL,
  `is_invalidated` tinyint(1) NOT NULL,
  `request_count_today` int(11) NOT NULL,
  `created_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Struktur dari tabel `otp_reset_password`
--

CREATE TABLE `otp_reset_password` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `otp` varchar(6) NOT NULL,
  `otp_expires_at` datetime NOT NULL,
  `is_used` tinyint(1) NOT NULL,
  `is_invalidated` tinyint(1) NOT NULL,
  `request_count_today` int(11) NOT NULL,
  `reset_token` varchar(255) DEFAULT NULL,
  `reset_token_expires_at` datetime DEFAULT NULL,
  `created_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- --------------------------------------------------------

--
-- Struktur dari tabel `pipeline_logs`
--

CREATE TABLE `pipeline_logs` (
  `id` int(11) NOT NULL,
  `chat_detail_id` int(11) NOT NULL,
  `latency_ms` int(11) DEFAULT NULL,
  `status` varchar(20) DEFAULT NULL,
  `error_message` text DEFAULT NULL,
  `input_tokens` int(11) DEFAULT NULL,
  `output_tokens` int(11) DEFAULT NULL,
  `total_cost` float DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data untuk tabel `pipeline_logs`
--

INSERT INTO `pipeline_logs` (`id`, `chat_detail_id`, `latency_ms`, `status`, `error_message`, `input_tokens`, `output_tokens`, `total_cost`) VALUES
(4, 4, 3839, 'success', NULL, 1, 8, 0),
(5, 5, 438, 'success', NULL, 2, 9, 0),
(6, 6, 466, 'success', NULL, 1, 7, 0),
(7, 7, 325292, 'success', NULL, 6, 457, 0),
(8, 8, 276229, 'success', NULL, 6, 471, 0),
(9, 9, 265313, 'success', NULL, 5, 278, 0);

-- --------------------------------------------------------

--
-- Struktur dari tabel `users`
--

CREATE TABLE `users` (
  `id` int(11) NOT NULL,
  `username` varchar(50) NOT NULL,
  `email` varchar(100) NOT NULL,
  `hashed_password` varchar(255) NOT NULL,
  `name` varchar(100) NOT NULL,
  `profile_image_url` varchar(255) DEFAULT NULL,
  `is_verified` tinyint(1) NOT NULL,
  `is_active` tinyint(1) NOT NULL,
  `last_active` datetime DEFAULT NULL,
  `created_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data untuk tabel `users`
--

INSERT INTO `users` (`id`, `username`, `email`, `hashed_password`, `name`, `profile_image_url`, `is_verified`, `is_active`, `last_active`, `created_at`) VALUES
(6, 'user', 'gregoriusnovantino17@gmail.com', '$2b$12$gtZa/NnjT6Yi0CYB40Owped8qkFuwOt5TAD148pNfrGq5S4w4iE3S', 'user', NULL, 1, 1, '2026-03-24 04:46:28', '2026-03-23 07:57:43');

-- --------------------------------------------------------

--
-- Struktur dari tabel `user_auth`
--

CREATE TABLE `user_auth` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `access_token` varchar(255) DEFAULT NULL,
  `access_token_expires_at` datetime DEFAULT NULL,
  `refresh_token` varchar(255) DEFAULT NULL,
  `refresh_token_expires_at` datetime DEFAULT NULL,
  `device_info` varchar(255) DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL,
  `created_at` datetime DEFAULT NULL,
  `updated_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Indexes for dumped tables
--

--
-- Indeks untuk tabel `alembic_version`
--
ALTER TABLE `alembic_version`
  ADD PRIMARY KEY (`version_num`);

--
-- Indeks untuk tabel `chats`
--
ALTER TABLE `chats`
  ADD PRIMARY KEY (`id`),
  ADD KEY `ix_chats_id` (`id`),
  ADD KEY `user_id` (`user_id`);

--
-- Indeks untuk tabel `chat_details`
--
ALTER TABLE `chat_details`
  ADD PRIMARY KEY (`id`),
  ADD KEY `ix_chat_details_id` (`id`),
  ADD KEY `chat_id` (`chat_id`);

--
-- Indeks untuk tabel `otp_change_email`
--
ALTER TABLE `otp_change_email`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `change_token` (`change_token`),
  ADD KEY `user_id` (`user_id`),
  ADD KEY `ix_otp_change_email_id` (`id`);

--
-- Indeks untuk tabel `otp_registrasi`
--
ALTER TABLE `otp_registrasi`
  ADD PRIMARY KEY (`id`),
  ADD KEY `ix_otp_registrasi_id` (`id`),
  ADD KEY `user_id` (`user_id`);

--
-- Indeks untuk tabel `otp_reset_password`
--
ALTER TABLE `otp_reset_password`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `reset_token` (`reset_token`),
  ADD KEY `ix_otp_reset_password_id` (`id`),
  ADD KEY `user_id` (`user_id`);

--
-- Indeks untuk tabel `pipeline_logs`
--
ALTER TABLE `pipeline_logs`
  ADD PRIMARY KEY (`id`),
  ADD KEY `ix_pipeline_logs_id` (`id`),
  ADD KEY `chat_detail_id` (`chat_detail_id`);

--
-- Indeks untuk tabel `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `ix_users_email` (`email`),
  ADD UNIQUE KEY `ix_users_username` (`username`),
  ADD KEY `ix_users_id` (`id`);

--
-- Indeks untuk tabel `user_auth`
--
ALTER TABLE `user_auth`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `access_token` (`access_token`),
  ADD UNIQUE KEY `refresh_token` (`refresh_token`),
  ADD KEY `ix_user_auth_id` (`id`),
  ADD KEY `ix_user_auth_user_id` (`user_id`);

--
-- AUTO_INCREMENT untuk tabel yang dibuang
--

--
-- AUTO_INCREMENT untuk tabel `chats`
--
ALTER TABLE `chats`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=10;

--
-- AUTO_INCREMENT untuk tabel `chat_details`
--
ALTER TABLE `chat_details`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=10;

--
-- AUTO_INCREMENT untuk tabel `otp_change_email`
--
ALTER TABLE `otp_change_email`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT untuk tabel `otp_registrasi`
--
ALTER TABLE `otp_registrasi`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=10;

--
-- AUTO_INCREMENT untuk tabel `otp_reset_password`
--
ALTER TABLE `otp_reset_password`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=8;

--
-- AUTO_INCREMENT untuk tabel `pipeline_logs`
--
ALTER TABLE `pipeline_logs`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=10;

--
-- AUTO_INCREMENT untuk tabel `users`
--
ALTER TABLE `users`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT untuk tabel `user_auth`
--
ALTER TABLE `user_auth`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=31;

--
-- Ketidakleluasaan untuk tabel pelimpahan (Dumped Tables)
--

--
-- Ketidakleluasaan untuk tabel `chats`
--
ALTER TABLE `chats`
  ADD CONSTRAINT `chats_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Ketidakleluasaan untuk tabel `chat_details`
--
ALTER TABLE `chat_details`
  ADD CONSTRAINT `chat_details_ibfk_1` FOREIGN KEY (`chat_id`) REFERENCES `chats` (`id`) ON DELETE CASCADE;

--
-- Ketidakleluasaan untuk tabel `otp_change_email`
--
ALTER TABLE `otp_change_email`
  ADD CONSTRAINT `otp_change_email_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Ketidakleluasaan untuk tabel `otp_registrasi`
--
ALTER TABLE `otp_registrasi`
  ADD CONSTRAINT `otp_registrasi_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Ketidakleluasaan untuk tabel `otp_reset_password`
--
ALTER TABLE `otp_reset_password`
  ADD CONSTRAINT `otp_reset_password_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Ketidakleluasaan untuk tabel `pipeline_logs`
--
ALTER TABLE `pipeline_logs`
  ADD CONSTRAINT `pipeline_logs_ibfk_1` FOREIGN KEY (`chat_detail_id`) REFERENCES `chat_details` (`id`) ON DELETE CASCADE;

--
-- Ketidakleluasaan untuk tabel `user_auth`
--
ALTER TABLE `user_auth`
  ADD CONSTRAINT `user_auth_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
