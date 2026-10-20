# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoAdmin
  module Qr
    # Encodeur QR code (ISO/IEC 18004), mode octet, correction d'erreur M,
    # versions 1 à 15 : porte l'URI `otpauth://` de l'enrôlement TOTP de
    # l'administration et de connect. Renvoie la matrice des modules, que
    # `Qr::Svg` dessine.
    #
    # Copie de `partiduo-app/src/auth/services/qr_code.cr` (pas de dépendance
    # de l'administration vers l'application) : le bloc `class QrCode … end`
    # est identique à la source, vérifié par `spec/admin/qr_code_spec.cr`
    # (empreinte SHA-256 du bloc, comparaison à la copie de travail voisine).
    # Ne pas le modifier ici : modifier partiduo-app, recopier, puis mettre à
    # jour l'empreinte de la spec.
    #
    # Algorithme d'après la bibliothèque de référence de Project Nayuki
    # (https://github.com/nayuki/QR-Code-generator, MIT, voir
    # THIRD-PARTY-LICENSES.txt).
    class QrCode
      MAX_VERSION = 15

      # Correction d'erreur M, versions 1 à 15.
      ECC_PER_BLOCK = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24]
      BLOCKS        = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10]
      ECC_M_BITS    = 0

      class TooLong < Exception
      end

      getter version : Int32
      getter size : Int32
      getter mask : Int32
      getter modules : Array(Array(Bool))

      @function : Array(Array(Bool))

      def self.encode(text : String) : QrCode
        data = text.to_slice
        version = (1..MAX_VERSION).find do |candidate|
          count_bits = candidate < 10 ? 8 : 16
          4 + count_bits + data.size * 8 <= data_codewords(candidate) * 8
        end
        raise TooLong.new("#{data.size} octets : trop long pour un QR code version #{MAX_VERSION}-M") if version.nil?
        new(version, data)
      end

      # Nombre de modules de données (hors motifs fonctionnels), en bits.
      def self.raw_data_modules(version : Int32) : Int32
        result = (16 * version + 128) * version + 64
        if version >= 2
          aligns = version // 7 + 2
          result -= (25 * aligns - 10) * aligns - 55
          result -= 36 if version >= 7
        end
        result
      end

      def self.data_codewords(version : Int32) : Int32
        raw_data_modules(version) // 8 - ECC_PER_BLOCK[version] * BLOCKS[version]
      end

      def initialize(@version : Int32, data : Bytes)
        @size = @version * 4 + 17
        @modules = Array.new(@size) { Array.new(@size, false) }
        @function = Array.new(@size) { Array.new(@size, false) }
        @mask = 0

        draw_function_patterns
        codewords = add_ecc_and_interleave(data_codewords_for(data))
        draw_codewords(codewords)

        best = 0
        best_penalty = Int32::MAX
        8.times do |candidate|
          apply_mask(candidate)
          draw_format_bits(candidate)
          penalty = penalty_score
          if penalty < best_penalty
            best = candidate
            best_penalty = penalty
          end
          apply_mask(candidate) # XOR : annule le masque
        end
        @mask = best
        apply_mask(best)
        draw_format_bits(best)
      end

      def dark?(x : Int32, y : Int32) : Bool
        @modules[y][x]
      end

      def function_module?(x : Int32, y : Int32) : Bool
        @function[y][x]
      end

      # Lignes de la matrice, `#` pour un module sombre (specs, débogage).
      def to_s(io : IO) : Nil
        @modules.each do |row|
          row.each { |dark| io << (dark ? '#' : '.') }
          io << '\n'
        end
      end

      # Positions des centres des motifs d'alignement.
      def self.alignment_positions(version : Int32) : Array(Int32)
        return [] of Int32 if version == 1
        aligns = version // 7 + 2
        size = version * 4 + 17
        step = (version * 8 + aligns * 3 + 5) // (aligns * 4 - 4) * 2
        result = [6]
        position = size - 7
        while result.size < aligns
          result.insert(1, position)
          position -= step
        end
        result
      end

      # Bits de format (15) pour un masque, correction M.
      def self.format_bits(mask : Int32) : Int32
        data = ECC_M_BITS << 3 | mask
        remainder = data
        10.times { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        (data << 10 | remainder) ^ 0x5412
      end

      def self.version_bits(version : Int32) : Int32
        remainder = version
        12.times { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        version << 12 | remainder
      end

      def self.mask_bit?(mask : Int32, x : Int32, y : Int32) : Bool
        case mask
        when 0 then (x + y) % 2 == 0
        when 1 then y % 2 == 0
        when 2 then x % 3 == 0
        when 3 then (x + y) % 3 == 0
        when 4 then (x // 3 + y // 2) % 2 == 0
        when 5 then x * y % 2 + x * y % 3 == 0
        when 6 then (x * y % 2 + x * y % 3) % 2 == 0
        else        ((x + y) % 2 + x * y % 3) % 2 == 0
        end
      end

      # Multiplication dans GF(2⁸), polynôme 0x11D.
      def self.gf_multiply(x : Int32, y : Int32) : Int32
        z = 0
        7.downto(0) do |i|
          z = (z << 1) ^ ((z >> 7) * 0x11D)
          z ^= ((y >> i) & 1) * x
        end
        z
      end

      def self.rs_divisor(degree : Int32) : Array(Int32)
        result = Array.new(degree, 0)
        result[degree - 1] = 1
        root = 1
        degree.times do
          degree.times do |j|
            result[j] = gf_multiply(result[j], root)
            result[j] ^= result[j + 1] if j + 1 < degree
          end
          root = gf_multiply(root, 0x02)
        end
        result
      end

      def self.rs_remainder(data : Array(Int32), divisor : Array(Int32)) : Array(Int32)
        result = Array.new(divisor.size, 0)
        data.each do |byte|
          factor = byte ^ result.shift
          result << 0
          divisor.each_with_index { |coefficient, i| result[i] ^= gf_multiply(coefficient, factor) }
        end
        result
      end

      private def set_function(x : Int32, y : Int32, dark : Bool) : Nil
        @modules[y][x] = dark
        @function[y][x] = true
      end

      private def draw_function_patterns : Nil
        @size.times do |i|
          set_function(6, i, i % 2 == 0)
          set_function(i, 6, i % 2 == 0)
        end
        draw_finder(3, 3)
        draw_finder(@size - 4, 3)
        draw_finder(3, @size - 4)

        positions = QrCode.alignment_positions(@version)
        last = positions.size - 1
        positions.each_with_index do |center_x, i|
          positions.each_with_index do |center_y, j|
            next if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0)
            (-2..2).each do |offset_y|
              (-2..2).each do |offset_x|
                set_function(center_x + offset_x, center_y + offset_y, {offset_x.abs, offset_y.abs}.max != 1)
              end
            end
          end
        end

        draw_format_bits(0) # réserve les zones de format
        draw_version
      end

      private def draw_finder(x : Int32, y : Int32) : Nil
        (-4..4).each do |offset_y|
          (-4..4).each do |offset_x|
            xx, yy = x + offset_x, y + offset_y
            next unless 0 <= xx < @size && 0 <= yy < @size
            distance = {offset_x.abs, offset_y.abs}.max
            set_function(xx, yy, distance != 2 && distance != 4)
          end
        end
      end

      private def draw_format_bits(mask : Int32) : Nil
        bits = QrCode.format_bits(mask)
        bit = ->(i : Int32) { (bits >> i) & 1 != 0 }
        (0..5).each { |i| set_function(8, i, bit.call(i)) }
        set_function(8, 7, bit.call(6))
        set_function(8, 8, bit.call(7))
        set_function(7, 8, bit.call(8))
        (9..14).each { |i| set_function(14 - i, 8, bit.call(i)) }
        (0..7).each { |i| set_function(@size - 1 - i, 8, bit.call(i)) }
        (8..14).each { |i| set_function(8, @size - 15 + i, bit.call(i)) }
        set_function(8, @size - 8, true) # module sombre fixe
      end

      private def draw_version : Nil
        return if @version < 7
        bits = QrCode.version_bits(@version)
        18.times do |i|
          dark = (bits >> i) & 1 != 0
          a = @size - 11 + i % 3
          b = i // 3
          set_function(a, b, dark)
          set_function(b, a, dark)
        end
      end

      # Segment octet, terminateur, bourrage (0xEC, 0x11).
      private def data_codewords_for(data : Bytes) : Array(Int32)
        capacity = QrCode.data_codewords(@version) * 8
        bits = [] of Bool
        append = ->(value : Int32, length : Int32) { (length - 1).downto(0) { |i| bits << ((value >> i) & 1 != 0) } }
        append.call(0b0100, 4)
        append.call(data.size, @version < 10 ? 8 : 16)
        data.each { |byte| append.call(byte.to_i32, 8) }
        append.call(0, {4, capacity - bits.size}.min)
        append.call(0, (8 - bits.size % 8) % 8)
        pad = 0xEC
        while bits.size < capacity
          append.call(pad, 8)
          pad ^= 0xEC ^ 0x11
        end
        bits.each_slice(8).map { |byte| byte.reduce(0) { |acc, b| (acc << 1) | (b ? 1 : 0) } }.to_a
      end

      private def add_ecc_and_interleave(data : Array(Int32)) : Array(Int32)
        blocks_count = BLOCKS[@version]
        ecc_length = ECC_PER_BLOCK[@version]
        raw = QrCode.raw_data_modules(@version) // 8
        short_blocks = blocks_count - raw % blocks_count
        short_length = raw // blocks_count
        divisor = QrCode.rs_divisor(ecc_length)

        blocks = [] of Array(Int32)
        offset = 0
        blocks_count.times do |i|
          length = short_length - ecc_length + (i < short_blocks ? 0 : 1)
          chunk = data[offset, length]
          offset += length
          ecc = QrCode.rs_remainder(chunk, divisor)
          chunk << 0 if i < short_blocks
          blocks << chunk + ecc
        end

        result = [] of Int32
        blocks.first.size.times do |i|
          blocks.each_with_index do |block, j|
            result << block[i] if i != short_length - ecc_length || j >= short_blocks
          end
        end
        result
      end

      # Placement en zigzag, par paires de colonnes, de droite à gauche.
      private def draw_codewords(codewords : Array(Int32)) : Nil
        index = 0
        total = codewords.size * 8
        right = @size - 1
        while right >= 1
          right = 5 if right == 6
          @size.times do |vertical|
            2.times do |j|
              x = right - j
              upward = (right + 1) & 2 == 0
              y = upward ? @size - 1 - vertical : vertical
              next if @function[y][x] || index >= total
              @modules[y][x] = (codewords[index >> 3] >> (7 - (index & 7))) & 1 != 0
              index += 1
            end
          end
          right -= 2
        end
      end

      private def apply_mask(mask : Int32) : Nil
        @size.times do |y|
          @size.times do |x|
            next if @function[y][x]
            @modules[y][x] ^= QrCode.mask_bit?(mask, x, y)
          end
        end
      end

      private def penalty_score : Int32
        penalty = 0
        # Règle 1 : suites de cinq modules identiques ou plus, en ligne et en colonne.
        @size.times do |i|
          penalty += run_penalty(Array.new(@size) { |j| @modules[i][j] })
          penalty += run_penalty(Array.new(@size) { |j| @modules[j][i] })
        end
        # Règle 2 : blocs 2×2 d'une même couleur.
        (@size - 1).times do |y|
          (@size - 1).times do |x|
            color = @modules[y][x]
            penalty += 3 if color == @modules[y][x + 1] && color == @modules[y + 1][x] && color == @modules[y + 1][x + 1]
          end
        end
        # Règle 4 : équilibre entre modules sombres et clairs.
        dark = @modules.sum(&.count(&.itself))
        total = @size * @size
        k = ((dark * 20 - total * 10).abs + total - 1) // total - 1
        penalty + k * 10
      end

      private def run_penalty(line : Array(Bool)) : Int32
        penalty = 0
        run = 1
        (1...line.size).each do |i|
          if line[i] == line[i - 1]
            run += 1
          else
            penalty += 3 + (run - 5) if run >= 5
            run = 1
          end
        end
        penalty += 3 + (run - 5) if run >= 5
        penalty
      end
    end
  end
end
