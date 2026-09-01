export interface PublicationConfig {
  legalPublisherName: string;
  supportEmail: string;
  copyrightYear: string;
  privacyEffectiveDate: string;
}

export function loadPublicationConfig(
  configPath?: string,
): Promise<PublicationConfig>;

export function validatePublicationConfig(
  config: PublicationConfig | unknown,
): string[];
