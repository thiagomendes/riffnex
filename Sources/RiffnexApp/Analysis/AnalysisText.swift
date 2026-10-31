import AnalysisEngine
import DesignSystem
import MusicCore

/// pt-BR copy for analysis concepts. Kept in one place so the wording stays honest and consistent.
enum AnalysisText {
    static func title(_ stage: AnalysisCoordinator.Stage) -> String {
        switch stage {
        case .decoding: "Lendo o áudio"
        case .musicUnderstanding: "Tempo, tom e seções"
        case .notes: "Detectando notas"
        case .assembling: "Montando acordes e seções"
        }
    }

    static func detail(_ stage: AnalysisCoordinator.Stage) -> String {
        switch stage {
        case .decoding: "Convertendo o arquivo para análise."
        case .musicUnderstanding: "Music Understanding da Apple. Não informa progresso, então mostramos só o tempo decorrido."
        case .notes: "Modelo Basic Pitch, janela por janela de 2 segundos."
        case .assembling: "Limpeza para guitarra, acordes por batida e rótulos de seção."
        }
    }

    static func qualityTitle(_ level: QualityReport.Level) -> String {
        switch level {
        case .good: "Boa confiabilidade"
        case .fair: "Confiabilidade moderada"
        case .limited: "Confiabilidade limitada"
        }
    }

    static func qualityPill(_ level: QualityReport.Level) -> RXStatusPill.Kind {
        switch level {
        case .good: .success
        case .fair: .warning
        case .limited: .failure
        }
    }

    static func reason(_ reason: QualityReport.Reason) -> String {
        switch reason {
        case .noBeatGrid: "Não encontramos uma grade de tempo; os acordes foram estimados em fatias de meio segundo."
        case .unsteadyTempo: "O andamento varia bastante; batidas e compassos podem estar desalinhados."
        case .noKey: "Não foi possível estimar o tom."
        case .vocalsDominant: "A voz domina a mixagem; algumas notas detectadas podem ser da voz, não da guitarra."
        case .fewNotes: "Poucas notas foram detectadas; a música pode ter pouca guitarra ou ser muito percussiva."
        case .manyLowConfidenceNotes: "Muitas notas têm confiança baixa; confira de ouvido antes de memorizar."
        case .denseTexture: "Arranjo muito denso; espere notas faltando e algumas a mais."
        case .littleGuitarLikeContent: "Há pouca atividade de instrumentos harmônicos (onde a guitarra se encaixa)."
        }
    }

    static func confidence(_ level: Confidence.Level) -> String {
        switch level {
        case .high: "alta"
        case .medium: "média"
        case .low: "baixa"
        }
    }

    static func sectionName(_ section: SongSection) -> String {
        switch section.kind {
        case .lettered: "Parte \(section.letter)"
        case .ending: "Final"
        case .silent: "Silêncio"
        }
    }

    static func stageError(_ stage: String) -> String {
        switch stage {
        case AnalysisCoordinator.Stage.musicUnderstanding.rawValue: "Tempo, tom e seções indisponíveis"
        default: stage
        }
    }
}
