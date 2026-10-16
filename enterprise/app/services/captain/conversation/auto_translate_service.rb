class Captain::Conversation::AutoTranslateService
  BATCH_LIMIT = 20
  MAX_CONTENT_LENGTH = 20_000
  BOT_SENDERS = %w[AgentBot Captain::Assistant].freeze

  pattr_initialize [:conversation!, :message_ids!, :target_language!]

  def perform
    own_language, foreign = untranslated.partition { |message| written_in_target?(message) }
    own_language.each { |message| store(message, message_text(message).original) }
    translate(foreign) if foreign.any?
    detect_conversation_language if conversation.language.blank?
    messages
  end

  private

  # Contact messages and bot replies both read in the contact language.
  def messages
    @messages ||= conversation.messages.where(id: message_ids.first(BATCH_LIMIT)).where.not(content: [nil, '']).order(:id)
                              .merge(Message.incoming.or(Message.where(sender_type: BOT_SENDERS)))
  end

  # A message too long for the model is returned as it is, so the dashboard stops asking for it.
  def untranslated
    @untranslated ||= messages.reject do |message|
      message.translations&.key?(target_language) || message_text(message).texts.sum(&:length) > MAX_CONTENT_LENGTH
    end
  end

  def written_in_target?(message)
    Captain::Llm::MessageTranslationService.same_language?(message.content_attributes['source_language'], target_language)
  end

  def message_text(message)
    @message_text ||= {}
    @message_text[message.id] ||= Captain::Conversation::MessageText.new(message)
  end

  # One model call for the batch: a segment per message, or per text node of an html email.
  def translate(pending)
    translations = translations_for(pending.flat_map { |message| message_text(message).texts })
    pending.each do |message|
      text = message_text(message)
      store(message, text.with(translations.shift(text.texts.size)))
    end
  end

  def translations_for(segments)
    response = Captain::Llm::MessageTranslationService.new(
      account: conversation.account, texts: segments, target_language: target_language, conversation_display_id: conversation.display_id
    ).perform
    raise StandardError, response[:error] if response[:error]
    raise StandardError, I18n.t('captain.translation_incomplete') if response[:message].size != segments.size

    response[:message]
  end

  # Under the row lock: another agent's translation or a deletion may have landed during the model call.
  def store(message, text)
    message.with_lock do
      message.update!(content_attributes: message.content_attributes.deep_merge('translations' => { target_language => text }))
    end
  end

  # Messages from before the feature carry no language; the thread follows its latest one.
  def detect_conversation_language
    return if untranslated.empty?

    text = message_text(untranslated.last).texts.join("\n")
    language = Captain::Llm::LanguageDetectionService.new(account: conversation.account, text: text).language
    conversation.update!(additional_attributes: conversation.additional_attributes.merge(conversation_language: language)) if language
  end
end
